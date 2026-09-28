import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:facebook_app_events/facebook_app_events.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:app_links/app_links.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'in_app_update_helper.dart';
import 'push_notification_helper.dart';

import 'webview_platform_stub.dart'
    if (dart.library.html) 'webview_platform.dart';

const _loginUrl =
    'https://stockspheres.in/';
const _checkoutLogoUrl = 'assets/app_icon.png';
const _checkoutLogoAsset = 'assets/app_icon.png';
const _appHost = 'stockspheres.in'; 

/// Web OAuth client ID from google-services.json (client_type: 3).
const _googleServerClientId =
    '717602572715-ot252eqti8govl48eu6q71591e5gauub.apps.googleusercontent.com';

/// Chrome-like UA so Google does not treat this as a blocked embedded WebView.
const _chromeMobileUserAgent =
    'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/121.0.0.0 Mobile Safari/537.36';

final _facebookAppEvents = FacebookAppEvents();

final GoogleSignIn _googleSignIn = GoogleSignIn(
  scopes: const ['email', 'profile'],
  serverClientId: _googleServerClientId,
);

void _initMetaAppEvents() {
  _facebookAppEvents.logEvent(name: 'app_open');
}

bool _isGoogleAuthUrl(String url) {
  final lower = url.toLowerCase();
  if (!(lower.startsWith('http://') || lower.startsWith('https://'))) {
    return false;
  }
  return lower.contains('accounts.google.com') ||
      lower.contains('google.com/o/oauth2') ||
      lower.contains('oauth2.googleapis.com') ||
      lower.contains('accounts.youtube.com') ||
      lower.contains('google.com/gsi/') ||
      lower.contains('googleapis.com/auth') ||
      lower.contains('appleid.apple.com') ||
      lower.contains('.firebaseapp.com/__/auth') ||
      lower.contains('firebaseapp.com/__/auth');
}

bool _isAppOwnedUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  return host == _appHost || host.endsWith('.$_appHost');
}

/// Replace web Firebase popup with native Google account picker bridge.
/// Always re-bind continueWithGoogle — page scripts can overwrite it after first inject.
const _nativeGoogleAuthBridgeScript = r'''
(function () {
  window.__onNativeGoogleAuth = async function (payload) {
    try {
      if (!payload || payload.error) {
        if (typeof setLoading === 'function') setLoading('btn_google', false);
        if (payload && payload.error && payload.error !== 'cancelled') {
          if (typeof showMsg === 'function') showMsg('error', payload.error);
        }
        return;
      }

      var name = (payload.name || '').trim();
      var email = (payload.email || '').trim();
      var photo = (payload.photo || '').trim();
      var idToken = payload.idToken || '';

      if (idToken && window.firebase && firebase.auth) {
        try {
          var cred = firebase.auth.GoogleAuthProvider.credential(idToken);
          await firebase.auth().signInWithCredential(cred);
        } catch (e) {
          console.warn('Firebase credential sign-in failed', e);
        }
      }

      if (!name || !email) {
        if (typeof showMsg === 'function') {
          showMsg('error', 'Could not get your Google profile details. Please fill the form manually.');
        }
        if (typeof setLoading === 'function') setLoading('btn_google', false);
        return;
      }

      var fd = new FormData();
      fd.append('name', name);
      fd.append('email', email);
      fd.append('photo', photo);
      var res = await fetch('api/social_register.php', { method: 'POST', body: fd });
      var data = await res.json();
      if (data.success) {
        if (typeof showMsg === 'function') showMsg('success', data.message);
        setTimeout(function () {
          window.location.href = data.redirect;
        }, 300);
      } else {
        if (typeof showMsg === 'function') showMsg('error', data.message || 'Registration failed');
        if (typeof setLoading === 'function') setLoading('btn_google', false);
      }
    } catch (e) {
      if (typeof setLoading === 'function') setLoading('btn_google', false);
      if (typeof showMsg === 'function') {
        showMsg('error', (e && e.message) || 'Google sign-in failed');
      }
    }
  };

  window.continueWithGoogle = async function () {
    try {
      if (typeof setLoading === 'function') setLoading('btn_google', true);
      if (typeof showMsg === 'function') showMsg('', '');
      if (window.NativeGoogleAuthBridge && window.NativeGoogleAuthBridge.postMessage) {
        window.NativeGoogleAuthBridge.postMessage('start');
        return;
      }
      if (typeof showMsg === 'function') {
        showMsg('error', 'Google sign-in is unavailable in this app build.');
      }
      if (typeof setLoading === 'function') setLoading('btn_google', false);
    } catch (e) {
      if (typeof setLoading === 'function') setLoading('btn_google', false);
    }
  };

  // Also bind the button directly in case onclick still points at old handler.
  var btn = document.getElementById('btn_google');
  if (btn && !btn.__novaNativeBound) {
    btn.__novaNativeBound = true;
    btn.addEventListener('click', function (ev) {
      ev.preventDefault();
      ev.stopPropagation();
      window.continueWithGoogle();
    }, true);
  }

  window.__novaNativeGoogleAuthReady = true;
})();
''';

const _nativeDownloadHookScript = r'''
(function () {
  if (window.__nativeDownloadHookReady) return;
  window.__nativeDownloadHookReady = true;
  window.__nativeBlobs = window.__nativeBlobs || {};

  function postDownload(payload) {
    if (window.BlobDownloadBridge && BlobDownloadBridge.postMessage) {
      BlobDownloadBridge.postMessage(JSON.stringify(payload));
    }
  }

  function findQrOrImage() {
    var canvases = document.querySelectorAll('canvas');
    for (var i = 0; i < canvases.length; i++) {
      try {
        var data = canvases[i].toDataURL('image/png');
        if (data && data.length > 100) {
          return { base64: data, filename: 'qr_code.png' };
        }
      } catch (e) {}
    }

    var imgs = document.querySelectorAll('img');
    var best = null;
    var bestScore = 0;
    for (var j = 0; j < imgs.length; j++) {
      var img = imgs[j];
      var w = img.naturalWidth || img.width || 0;
      var h = img.naturalHeight || img.height || 0;
      if (w < 80 || h < 80) continue;
      var meta = ((img.alt || '') + ' ' + (img.id || '') + ' ' +
        (img.className || '') + ' ' + (img.src || '')).toLowerCase();
      var score = Math.min(w, h);
      if (meta.indexOf('qr') !== -1 || meta.indexOf('phonepe') !== -1 ||
          meta.indexOf('upi') !== -1) {
        score += 1000;
      }
      if (Math.abs(w - h) < 30) score += 80;
      if (score > bestScore) {
        bestScore = score;
        best = img;
      }
    }
    if (!best) return null;
    if (best.src && best.src.indexOf('data:') === 0) {
      return { base64: best.src, filename: 'qr_code.png' };
    }
    try {
      var canvas = document.createElement('canvas');
      canvas.width = best.naturalWidth || best.width;
      canvas.height = best.naturalHeight || best.height;
      canvas.getContext('2d').drawImage(best, 0, 0);
      return { base64: canvas.toDataURL('image/png'), filename: 'qr_code.png' };
    } catch (e) {
      if (best.src && (best.src.indexOf('http://') === 0 || best.src.indexOf('https://') === 0)) {
        return { imageUrl: best.src, filename: 'qr_code.png' };
      }
    }
    return null;
  }

  function readBlobObject(blob, filename) {
    return new Promise(function (resolve, reject) {
      var reader = new FileReader();
      reader.onloadend = function () {
        if (reader.result) {
          resolve({ base64: reader.result, filename: filename || '' });
        } else {
          reject(new Error('empty file'));
        }
      };
      reader.onerror = function () { reject(reader.error || new Error('read failed')); };
      reader.readAsDataURL(blob);
    });
  }

  window.__readNativeDownload = function (url, filename) {
    return new Promise(function (resolve) {
      function fail() {
        var fallback = findQrOrImage();
        resolve(fallback || { error: 'Unable to download file' });
      }

      try {
        if (!url) {
          fail();
          return;
        }
        if (url.indexOf('data:') === 0) {
          resolve({ base64: url, filename: filename || 'qr_code.png' });
          return;
        }
        var stored = window.__nativeBlobs[url];
        if (stored) {
          readBlobObject(stored, filename || 'qr_code.png').then(resolve).catch(fail);
          return;
        }
        fetch(url).then(function (res) {
          return res.blob();
        }).then(function (blob) {
          return readBlobObject(blob, filename || '');
        }).then(resolve).catch(fail);
      } catch (e) {
        fail();
      }
    });
  };

  try {
    var origCreate = URL.createObjectURL.bind(URL);
    URL.createObjectURL = function (obj) {
      var objectUrl = origCreate(obj);
      if (obj) window.__nativeBlobs[objectUrl] = obj;
      return objectUrl;
    };
  } catch (e) {}

  document.addEventListener('click', function (event) {
    var link = event.target && event.target.closest
      ? event.target.closest('a[download]')
      : null;
    if (!link) return;
    var href = link.href || link.getAttribute('href') || '';
    if (!href) return;
    if (href.indexOf('blob:') !== 0 && href.indexOf('data:') !== 0) return;
    event.preventDefault();
    event.stopPropagation();
    window.__readNativeDownload(href, link.getAttribute('download') || 'qr_code.png')
      .then(postDownload);
  }, true);
})();
''';

const _razorpayHijackScript = r'''
(function () {
  if (window.__nativeRazorpayHijackReady) return;
  window.__nativeRazorpayHijackReady = true;
  window.__rzpHandlerId = 0;
  window.__rzpHandlers = {};

  function stripFunctions(options, handlerId) {
    const handlers = window.__rzpHandlers[handlerId] = {
      handler: typeof options.handler === 'function' ? options.handler : null,
      ondismiss:
        options.modal && typeof options.modal.ondismiss === 'function'
          ? options.modal.ondismiss
          : null,
      events: {},
    };

    const copy = {};
    for (const key in options) {
      if (!Object.prototype.hasOwnProperty.call(options, key)) continue;
      const value = options[key];
      if (typeof value === 'function') continue;
      if (key === 'modal' && value && typeof value === 'object') {
        const modalCopy = {};
        for (const modalKey in value) {
          if (
            Object.prototype.hasOwnProperty.call(value, modalKey) &&
            typeof value[modalKey] !== 'function'
          ) {
            modalCopy[modalKey] = value[modalKey];
          }
        }
        copy.modal = modalCopy;
        continue;
      }
      copy[key] = value;
    }
    copy.__handlerId = handlerId;
    return copy;
  }

  function createNativeRazorpayClass() {
    function NativeRazorpay(options) {
      this._options = options || {};
      this._handlerId = ++window.__rzpHandlerId;
      this._events = {};
    }

    NativeRazorpay.prototype.open = function () {
      try {
        const payload = stripFunctions(this._options, this._handlerId);
        const stored = window.__rzpHandlers[this._handlerId];
        if (stored) stored.events = this._events;
        NativeRazorpayBridge.postMessage(JSON.stringify(payload));
      } catch (error) {
        console.error('Native Razorpay bridge failed', error);
      }
    };

    NativeRazorpay.prototype.on = function (event, callback) {
      if (typeof callback === 'function') {
        this._events[event] = callback;
        const stored = window.__rzpHandlers[this._handlerId];
        if (stored) stored.events[event] = callback;
      }
    };

    NativeRazorpay.__isNativeBridge = true;
    return NativeRazorpay;
  }

  function hijackExistingRazorpay() {
    const current = window.Razorpay;
    if (!current || current.__isNativeBridge) return;

    const NativeRazorpay = createNativeRazorpayClass();
    try {
      window.Razorpay = NativeRazorpay;
    } catch (error) {
      console.error('Unable to replace Razorpay constructor', error);
    }
  }

  try {
    let currentRazorpay = window.Razorpay;
    Object.defineProperty(window, 'Razorpay', {
      configurable: true,
      enumerable: true,
      get: function () {
        return currentRazorpay;
      },
      set: function (value) {
        if (typeof value === 'function' && !value.__isNativeBridge) {
          currentRazorpay = createNativeRazorpayClass();
        } else {
          currentRazorpay = value;
        }
      },
    });
  } catch (error) {
    hijackExistingRazorpay();
  }

  hijackExistingRazorpay();
  setInterval(hijackExistingRazorpay, 1000);

  window.openNativeRazorpay = function (options) {
    const instance = new window.Razorpay(options || {});
    instance.open();
  };

  window.addEventListener('nativeRazorpayResult', function (event) {
    const detail = event.detail || {};
    const handlerId = detail.handlerId;
    const handlers = window.__rzpHandlers[handlerId];
    if (!handlers) return;

    if (detail.status === 'success' && handlers.handler) {
      handlers.handler({
        razorpay_payment_id: detail.data.paymentId,
        razorpay_order_id: detail.data.orderId,
        razorpay_signature: detail.data.signature,
      });
      return;
    }

    if (detail.status === 'error') {
      const failedHandler = handlers.events['payment.failed'];
      if (failedHandler) {
        failedHandler({
          error: {
            code: detail.data.code,
            description: detail.data.message,
            source: 'native',
            step: 'payment',
            reason: detail.data.message,
          },
        });
      }
      if (handlers.ondismiss) handlers.ondismiss();
    }
  });
})();
''';

Future<void> _requestPermissions() async {
  if (kIsWeb) return;
  await Permission.notification.request();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerWebViewPlatform();
  if (!kIsWeb) {
    _initMetaAppEvents();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await PushNotificationHelper().init();
  }
  runApp(const StockSpheresApp());
}

class StockSpheresApp extends StatelessWidget {
  const StockSpheresApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Stock Spheres',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7ED321),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const StockSpheresWebView(),
    );
  }
}

class StockSpheresWebView extends StatefulWidget {
  const StockSpheresWebView({super.key});

  @override
  State<StockSpheresWebView> createState() => _StockSpheresWebViewState();
}

class _StockSpheresWebViewState extends State<StockSpheresWebView>
    with WidgetsBindingObserver {
  static const _nativeRazorpayBridgeName = 'NativeRazorpayBridge';

  WebViewController? _controller;
  late final Razorpay _razorpay;
  final _appLinks = AppLinks();
  final _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  var _isLoading = true;
  var _loadProgress = 0;
  var _isOffline = false;
  var _hasPageError = false;
  var _isRetrying = false;
  var _didLoadSuccessfully = false;
  var _loadGeneration = 0;
  var _downloadDialogOpen = false;
  DateTime? _ignoreWebErrorsUntil;
  String? _checkoutLogoDataUri;

  bool get _showErrorScreen => _isOffline || _hasPageError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PushNotificationHelper.onTokenChanged = (_) => _sendFCMTokenToWeb();
    _razorpay = Razorpay()
      ..on(Razorpay.EVENT_PAYMENT_SUCCESS, _handlePaymentSuccess)
      ..on(Razorpay.EVENT_PAYMENT_ERROR, _handlePaymentError)
      ..on(Razorpay.EVENT_EXTERNAL_WALLET, _handleExternalWallet);
    _initConnectivity();
    _initWebView();
    _initDeepLinks();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForAppUpdate();
    });
  }

  Future<void> _loadCheckoutLogo() async {
    try {
      final bytes = await rootBundle.load(_checkoutLogoAsset);
      final base64Logo = base64Encode(bytes.buffer.asUint8List());
      _checkoutLogoDataUri = 'data:image/png;base64,$base64Logo';
    } catch (error) {
      debugPrint('Checkout logo asset missing, using remote logo: $error');
      _checkoutLogoDataUri = _checkoutLogoUrl;
    }
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    PushNotificationHelper.onTokenChanged = null;
    _razorpay.clear();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkConnectivity();
      _checkForAppUpdate();
    }
  }

  Future<void> _checkForAppUpdate() async {
    if (!mounted) return;
    await InAppUpdateHelper.checkAndPrompt(context);
  }

  Future<void> _initConnectivity() async {
    if (kIsWeb) return;
    await _checkConnectivity();
    _connectivitySub = _connectivity.onConnectivityChanged.listen((results) {
      _handleConnectivityResults(results);
    });
  }

  Future<void> _checkConnectivity() async {
    if (kIsWeb) return;
    try {
      final results = await _connectivity.checkConnectivity();
      _handleConnectivityResults(results);
    } catch (e) {
      debugPrint('Connectivity check failed: $e');
    }
  }

  void _handleConnectivityResults(List<ConnectivityResult> results) {
    final offline = results.isEmpty ||
        results.every((r) => r == ConnectivityResult.none);
    if (!mounted) return;

    final wasOffline = _isOffline;
    setState(() => _isOffline = offline);

    // Came back online — reload current page.
    if (wasOffline && !offline) {
      setState(() {
        _hasPageError = false;
        _isRetrying = true;
      });
      _retryAfterNetworkRestored();
    }
  }

  Future<void> _retryAfterNetworkRestored() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.reload();
    } catch (_) {
      await controller.loadRequest(Uri.parse(_loginUrl));
    }
  }

  Future<void> _onRetryNetworkPressed() async {
    if (!mounted) return;
    setState(() {
      _hasPageError = false;
      _isRetrying = true;
      _isLoading = true;
      _loadProgress = 0;
    });
    await _checkConnectivity();
    if (!mounted) return;
    if (_isOffline) {
      setState(() {
        _isLoading = false;
        _isRetrying = false;
      });
      return;
    }
    await _retryAfterNetworkRestored();
  }

  bool get _shouldIgnoreWebErrors {
    final until = _ignoreWebErrorsUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  bool _isMainFrameLoadError(WebResourceError error) {
    // Uploads, XHR, and cancelled requests often omit or mis-report the frame.
    // Only a confirmed main-document failure should cover the app.
    if (error.isForMainFrame != true) return false;
    if (_shouldIgnoreWebErrors) return false;

    final desc = error.description.toLowerCase();
    final code = error.errorCode;
    if (desc.contains('file://') ||
        desc.contains('content://') ||
        desc.contains('blob:') ||
        desc.contains('err_aborted') ||
        desc.contains('err_failed') ||
        desc.contains('err_cache') ||
        code == -1 ||
        code == -2 ||
        code == -3) {
      return false;
    }

    return error.errorType == WebResourceErrorType.hostLookup ||
        error.errorType == WebResourceErrorType.timeout ||
        error.errorType == WebResourceErrorType.connect ||
        error.errorType == WebResourceErrorType.failedSslHandshake ||
        desc.contains('err_name_not_resolved') ||
        desc.contains('err_name_resolution') ||
        desc.contains('err_internet_disconnected') ||
        desc.contains('err_address_unreachable') ||
        desc.contains('err_connection_refused') ||
        desc.contains('err_connection_timed_out') ||
        desc.contains('err_timed_out') ||
        desc.contains('err_ssl') ||
        desc.contains('err_cert') ||
        code == -6 ||
        code == -7 ||
        code == -105 ||
        code == -106 ||
        code == -118 ||
        code == -137;
  }

  Future<void> _handlePageFinished(
    WebViewController controller,
    String url,
  ) async {
    final generation = _loadGeneration;
    if (await _looksLikeSystemErrorPage(controller)) {
      if (!mounted || generation != _loadGeneration) return;
      _onMainFrameLoadFailed();
      return;
    }
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _hasPageError = false;
      _isRetrying = false;
      _isLoading = false;
      _didLoadSuccessfully = true;
    });
    _injectNativeBridges(controller);
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      if (mounted && !_hasPageError) _injectNativeBridges(controller);
    });
    Future<void>.delayed(const Duration(milliseconds: 1200), () {
      if (mounted && !_hasPageError) _injectNativeBridges(controller);
    });
    _sendFCMTokenToWeb();
  }

  void _onMainFrameLoadFailed() {
    if (!mounted) return;
    setState(() {
      _hasPageError = true;
      _isRetrying = false;
      _isLoading = false;
    });
  }

  Future<bool> _looksLikeSystemErrorPage(WebViewController controller) async {
    try {
      final title = (await controller.getTitle() ?? '').toLowerCase();
      if (title.contains('webpage not available') ||
          title.contains('web page not available') ||
          title.contains('site can’t be reached') ||
          title.contains("site can't be reached") ||
          title.contains("this page isn't working") ||
          title.contains('this site can’t be reached')) {
        return true;
      }
      final result = await controller.runJavaScriptReturningResult(
        "(document.body && document.body.innerText) ? document.body.innerText : ''",
      );
      final text = result.toString().toLowerCase();
      return text.contains('webpage not available') &&
          text.contains('net::err_');
    } catch (_) {
      return false;
    }
  }

  Future<void> _initDeepLinks() async {
    if (kIsWeb) return;
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        _handleIncomingAppLink(initial);
      }
      _appLinks.uriLinkStream.listen(_handleIncomingAppLink);
    } catch (e) {
      debugPrint('Deep link init failed: $e');
    }
  }

  void _handleIncomingAppLink(Uri uri) {
    if (!_isAppOwnedUrl(uri.toString())) return;
    final controller = _controller;
    if (controller == null) return;
    debugPrint('Opening app deep link in WebView: $uri');
    controller.loadRequest(uri);
  }

  Future<void> _initWebView() async {
    await _requestPermissions();
    await _loadCheckoutLogo();

    late final WebViewController controller;
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0A192F))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (!mounted) return;
            setState(() {
              _loadProgress = progress;
              _isLoading = progress < 100;
            });
          },
          onPageStarted: (_) {
            if (!mounted) return;
            _loadGeneration++;
            setState(() => _isLoading = true);
            _injectNativeBridges(controller);
          },
          onPageFinished: (url) {
            _handlePageFinished(controller, url);
          },
          onNavigationRequest: (request) {
            final url = request.url;
            final lowerUrl = url.toLowerCase();

            // Firebase / Google / Apple auth MUST stay in this WebView.
            // External Chrome breaks signInWithRedirect sessionStorage.
            if (_isGoogleAuthUrl(url) ||
                lowerUrl.contains('firebaseapp.com') ||
                lowerUrl.contains('firebaseauth')) {
              debugPrint('Allowing auth navigation in WebView: $url');
              return NavigationDecision.navigate;
            }
            
            // Handle Razorpay
            if (lowerUrl.contains('checkout.razorpay.com') ||
                lowerUrl.contains('api.razorpay.com/v1/checkout') ||
                lowerUrl.contains('razorpay.com/v1/checkout')) {
              debugPrint('Blocked Razorpay web checkout: $url');
              return NavigationDecision.prevent;
            }

            // Handle Android intent scheme
            if (lowerUrl.startsWith('intent://')) {
              final parsedUrl = _parseIntentUrl(url);
              if (parsedUrl != null) {
                final parsedUri = Uri.tryParse(parsedUrl);
                if (parsedUri != null) {
                  _launchExternal(parsedUri);
                }
              }
              return NavigationDecision.prevent;
            }

            // Handle Blob / data-URI downloads (QR code, invoices, etc.)
            if (url.startsWith('blob:') || url.startsWith('data:')) {
              _handleBlobUrl(url);
              return NavigationDecision.prevent;
            }

            // Handle standard external schemes
            if (!lowerUrl.startsWith('http://') && !lowerUrl.startsWith('https://')) {
              final uri = Uri.tryParse(url);
              if (uri != null) {
                _launchExternal(uri);
              }
              return NavigationDecision.prevent;
            }

            // Handle specific external website links that should open in external app
            if (lowerUrl.contains('maps.google.com') ||
                lowerUrl.contains('google.com/maps') ||
                lowerUrl.contains('maps.apple.com') ||
                lowerUrl.contains('wa.me') ||
                lowerUrl.contains('whatsapp.com')) {
              final uri = Uri.tryParse(url);
              if (uri != null) {
                _launchExternal(uri);
              }
              return NavigationDecision.prevent;
            }

            // Handle file download/invoice links to download internally
            bool isDownloadLink = false;
            if (lowerUrl.contains('.pdf') ||
                lowerUrl.contains('.xlsx') ||
                lowerUrl.contains('.xls') ||
                lowerUrl.contains('download') ||
                lowerUrl.contains('print') ||
                lowerUrl.contains('export') ||
                lowerUrl.contains('pdf')) {
              isDownloadLink = true;
            } else if (lowerUrl.contains('invoice') ||
                       lowerUrl.contains('receipt') ||
                       lowerUrl.contains('bill')) {
              // If it's a web page (.php, .html, .htm), open it in the webview
              // instead of downloading it, unless it's explicitly a download/print/export URL.
              if (lowerUrl.contains('.php') ||
                  lowerUrl.contains('.html') ||
                  lowerUrl.contains('.htm')) {
                isDownloadLink = false;
              } else {
                isDownloadLink = true;
              }
            }

            if (isDownloadLink) {
              if (url.startsWith('http://') || url.startsWith('https://')) {
                _downloadAndShareFile(url);
              } else {
                final uri = Uri.tryParse(url);
                if (uri != null) {
                  _launchExternal(uri);
                }
              }
              return NavigationDecision.prevent;
            }

            return NavigationDecision.navigate;
          },
          onHttpError: (error) {
            final status = error.response?.statusCode ?? 0;
            debugPrint('WebView HTTP error: $status ${error.request?.uri}');
          },
          onWebResourceError: (error) {
            debugPrint(
              'WebView error: code=${error.errorCode} '
              'type=${error.errorType} main=${error.isForMainFrame} '
              '${error.description}',
            );
            if (_isMainFrameLoadError(error)) {
              _onMainFrameLoadFailed();
            }
          },
        ),
      )
      ..addJavaScriptChannel(
        _nativeRazorpayBridgeName,
        onMessageReceived: _onRazorpayRequest,
      )
      ..addJavaScriptChannel(
        'FCMTokenBridge',
        onMessageReceived: (JavaScriptMessage message) {
          final payload = message.message.trim();
          if (payload == 'getToken') {
            _sendFCMTokenToWeb();
          }
        },
      )
      ..addJavaScriptChannel(
        'NativeGoogleAuthBridge',
        onMessageReceived: (JavaScriptMessage message) {
          final action = message.message.trim();
          if (action == 'start') {
            _startNativeGoogleSignIn();
          }
        },
      )
      ..addJavaScriptChannel(
        'GoogleAuthBridge',
        onMessageReceived: (JavaScriptMessage message) {
          // Legacy channel — keep auth inside WebView if anything still posts here.
          final url = message.message.trim();
          if (url.isEmpty) return;
          final uri = Uri.tryParse(url);
          if (uri == null) return;
          _controller?.loadRequest(uri);
        },
      )
      ..addJavaScriptChannel(
        'BlobDownloadBridge',
        onMessageReceived: _onBlobDownloadMessage,
      );

    if (!kIsWeb && controller.platform is AndroidWebViewController) {
      final androidController =
          controller.platform as AndroidWebViewController;
      await androidController.setUserAgent(_chromeMobileUserAgent);
      await androidController.setOnShowFileSelector((params) async {
        _ignoreWebErrorsUntil =
            DateTime.now().add(const Duration(seconds: 30));
        if (_hasPageError && mounted) {
          setState(() => _hasPageError = false);
        }
        final ImagePicker picker = ImagePicker();
        final source = await showModalBottomSheet<ImageSource>(
          context: context,
          builder: (context) => SafeArea(
            child: Wrap(
              children: [
                ListTile(
                  leading: const Icon(Icons.photo_library),
                  title: const Text('Choose from Gallery'),
                  onTap: () => Navigator.pop(context, ImageSource.gallery),
                ),
                ListTile(
                  leading: const Icon(Icons.camera_alt),
                  title: const Text('Take Photo (Camera)'),
                  onTap: () => Navigator.pop(context, ImageSource.camera),
                ),
              ],
            ),
          ),
        );

        if (source == null) return [];

        try {
          final XFile? file = await picker.pickImage(
            source: source,
            imageQuality: 85,
          );
          if (file != null) {
            _ignoreWebErrorsUntil =
                DateTime.now().add(const Duration(seconds: 8));
            return [Uri.file(file.path).toString()];
          }
        } catch (e) {
          debugPrint('Error picking image: $e');
        }
        return [];
      });
    }

    await controller.loadRequest(Uri.parse(_loginUrl));

    if (!mounted) return;
    setState(() => _controller = controller);
  }

  Future<void> _injectNativeBridges(WebViewController controller) async {
    await controller.runJavaScript(_nativeDownloadHookScript);
    await controller.runJavaScript(_razorpayHijackScript);
    await controller.runJavaScript(_nativeGoogleAuthBridgeScript);
  }

  Future<void> _startNativeGoogleSignIn() async {
    if (kIsWeb) return;
    try {
      debugPrint('Native Google Sign-In starting...');
      // Clear any cached Google session so the account picker is shown.
      try {
        await _googleSignIn.disconnect();
      } catch (_) {
        await _googleSignIn.signOut();
      }
      // Let WebView release focus before opening the system account UI.
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final account = await _googleSignIn.signIn();
      debugPrint('Native Google Sign-In result: ${account?.email}');
      if (account == null) {
        await _sendNativeGoogleAuthToWeb({'error': 'cancelled'});
        return;
      }

      final auth = await account.authentication;
      final idToken = auth.idToken;
      await _sendNativeGoogleAuthToWeb({
        'name': account.displayName ?? '',
        'email': account.email,
        'photo': account.photoUrl ?? '',
        if (idToken != null && idToken.isNotEmpty) 'idToken': idToken,
      });
    } on PlatformException catch (e) {
      debugPrint('Google PlatformException: ${e.code} ${e.message}');
      final cancelled =
          e.code == 'sign_in_canceled' || e.code == 'sign_in_cancelled';
      final raw = '${e.message ?? ''} ${e.details ?? ''}';
      final isDeveloperError = raw.contains('ApiException: 10') ||
          raw.contains('DEVELOPER_ERROR') ||
          e.code == 'sign_in_failed';
      await _sendNativeGoogleAuthToWeb({
        'error': cancelled
            ? 'cancelled'
            : isDeveloperError
                ? 'Google Sign-In setup incomplete. Add this app SHA-1 fingerprint in Firebase Console (Project settings → Your apps → com.stocksphere.app), then download a new google-services.json.'
                : (e.message ?? 'Google sign-in failed.'),
      });
    } catch (e) {
      debugPrint('Native Google sign-in failed: $e');
      final raw = e.toString();
      final isDeveloperError = raw.contains('ApiException: 10') ||
          raw.contains('DEVELOPER_ERROR');
      await _sendNativeGoogleAuthToWeb({
        'error': isDeveloperError
            ? 'Google Sign-In setup incomplete. Add this app SHA-1 fingerprint in Firebase Console (Project settings → Your apps → com.stocksphere.app), then download a new google-services.json.'
            : 'Google sign-in failed. Please try again.',
      });
    }
  }

  Future<void> _sendNativeGoogleAuthToWeb(Map<String, dynamic> payload) async {
    final controller = _controller;
    if (controller == null) return;
    final escaped = jsonEncode(payload);
    final script = '''
      (function () {
        if (typeof window.__onNativeGoogleAuth === 'function') {
          window.__onNativeGoogleAuth($escaped);
        }
      })();
    ''';
    try {
      await controller.runJavaScript(script);
    } catch (e) {
      debugPrint('Failed to send Google auth result to WebView: $e');
    }
  }

  Future<void> _sendFCMTokenToWeb() async {
    final token = PushNotificationHelper().fcmToken;
    if (token == null) {
      debugPrint('FCM Token is null, cannot send to web');
      return;
    }
    final controller = _controller;
    if (controller == null) return;

    final script = '''
      (function () {
        if (typeof window.onFCMTokenReceived === 'function') {
          window.onFCMTokenReceived("$token");
        }
        const event = new CustomEvent('fcmTokenReceived', {
          detail: { token: "$token" }
        });
        window.dispatchEvent(event);
      })();
    ''';
    try {
      await controller.runJavaScript(script);
      debugPrint('Successfully injected FCM token to WebView: $token');
    } catch (e) {
      debugPrint('Error injecting FCM token: $e');
    }
  }

  void _showDownloadDialog(String message) {
    if (_downloadDialogOpen || !mounted) return;
    _downloadDialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Expanded(child: Text(message)),
            ],
          ),
        );
      },
    );
  }

  void _hideDownloadDialog() {
    if (!_downloadDialogOpen || !mounted) return;
    _downloadDialogOpen = false;
    Navigator.of(context, rootNavigator: true).pop();
  }

  Future<void> _shareDownloadedBytes({
    required List<int> bytes,
    required String filename,
    required String mimeType,
    required String shareText,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final safeName = filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final filePath = '${tempDir.path}/$safeName';
    final file = File(filePath);
    await file.writeAsBytes(bytes);
    final xFile = XFile(filePath, mimeType: mimeType, name: safeName);
    // ignore: deprecated_member_use
    await Share.shareXFiles([xFile], text: shareText);
  }

  ({String mimeType, String ext, String filename, String shareText})
      _downloadMeta({
    required String mimeHint,
    String? suggestedName,
  }) {
    var mimeType = 'application/octet-stream';
    var ext = 'bin';
    var shareText = 'Downloaded file';
    final hint = mimeHint.toLowerCase();
    final name = (suggestedName ?? '').trim();

    if (hint.contains('image/png') || hint.endsWith('.png')) {
      mimeType = 'image/png';
      ext = 'png';
      shareText = 'QR Code';
    } else if (hint.contains('image/jpeg') ||
        hint.contains('image/jpg') ||
        hint.endsWith('.jpg') ||
        hint.endsWith('.jpeg')) {
      mimeType = 'image/jpeg';
      ext = 'jpg';
      shareText = 'QR Code';
    } else if (hint.contains('image/webp')) {
      mimeType = 'image/webp';
      ext = 'webp';
      shareText = 'QR Code';
    } else if (hint.contains('image/')) {
      mimeType = 'image/png';
      ext = 'png';
      shareText = 'QR Code';
    } else if (hint.contains('application/pdf') || hint.endsWith('.pdf')) {
      mimeType = 'application/pdf';
      ext = 'pdf';
      shareText = 'Invoice';
    } else if (hint.contains('spreadsheetml') || hint.endsWith('.xlsx')) {
      mimeType =
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      ext = 'xlsx';
      shareText = 'Export';
    } else if (hint.contains('ms-excel') || hint.endsWith('.xls')) {
      mimeType = 'application/vnd.ms-excel';
      ext = 'xls';
      shareText = 'Export';
    }

    final filename = name.isNotEmpty
        ? (name.contains('.') ? name : '$name.$ext')
        : (shareText == 'QR Code' ? 'qr_code.$ext' : 'download.$ext');
    return (
      mimeType: mimeType,
      ext: ext,
      filename: filename,
      shareText: shareText,
    );
  }

  Future<void> _downloadAndShareFile(String url) async {
    _showDownloadDialog('Downloading file...');

    try {
      final result =
          await _controller?.runJavaScriptReturningResult('document.cookie');
      var cookies = '';
      if (result != null) {
        cookies = result.toString();
        if (cookies.startsWith('"') && cookies.endsWith('"')) {
          cookies = cookies.substring(1, cookies.length - 1);
        }
      }

      final response = await http.get(
        Uri.parse(url),
        headers: {
          if (cookies.isNotEmpty) 'Cookie': cookies,
        },
      );

      _hideDownloadDialog();

      if (response.statusCode != 200) {
        throw Exception('Server returned status code: ${response.statusCode}');
      }

      var suggestedName = '';
      final contentDisposition = response.headers['content-disposition'] ??
          response.headers['Content-Disposition'];
      if (contentDisposition != null) {
        final match =
            RegExp(r'''filename=["']?([^"']+)["']?''').firstMatch(contentDisposition);
        if (match != null && match.groupCount >= 1) {
          suggestedName = match.group(1)!;
        }
      }
      if (suggestedName.isEmpty) {
        try {
          final lastSegment = Uri.parse(url).pathSegments.last;
          if (lastSegment.isNotEmpty && lastSegment.contains('.')) {
            suggestedName = lastSegment;
          }
        } catch (_) {}
      }

      final contentType = response.headers['content-type'] ?? '';
      final meta = _downloadMeta(
        mimeHint: '$contentType $suggestedName $url',
        suggestedName: suggestedName,
      );
      await _shareDownloadedBytes(
        bytes: response.bodyBytes,
        filename: meta.filename,
        mimeType: meta.mimeType,
        shareText: meta.shareText,
      );
    } catch (e) {
      _hideDownloadDialog();
      debugPrint('Error downloading file: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to download file')),
        );
      }
    }
  }

  Future<void> _handleBlobUrl(String sourceUrl) async {
    final controller = _controller;
    if (controller == null) return;

    _showDownloadDialog('Preparing download...');

    final escaped = jsonEncode(sourceUrl);
    final jsCode = '''
      (async function () {
        try {
          var result;
          if (typeof window.__readNativeDownload === 'function') {
            result = await window.__readNativeDownload($escaped);
          } else {
            result = { error: 'Download helper not ready' };
          }
          BlobDownloadBridge.postMessage(JSON.stringify(result));
        } catch (e) {
          BlobDownloadBridge.postMessage(JSON.stringify({
            error: (e && e.message) ? e.message : 'Download failed'
          }));
        }
      })();
    ''';

    try {
      await controller.runJavaScript(jsCode);
    } catch (e) {
      debugPrint('Error running blob download JS: $e');
      _hideDownloadDialog();
    }
  }

  Future<void> _onBlobDownloadMessage(JavaScriptMessage message) async {
    try {
      final data = jsonDecode(message.message);
      if (data is! Map) {
        _hideDownloadDialog();
        return;
      }

      if (data['error'] != null) {
        _hideDownloadDialog();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to download file')),
          );
        }
        return;
      }

      final imageUrl = data['imageUrl']?.toString() ?? '';
      if (imageUrl.startsWith('http://') || imageUrl.startsWith('https://')) {
        _hideDownloadDialog();
        await _downloadAndShareFile(imageUrl);
        return;
      }

      final base64Str = data['base64']?.toString() ?? '';
      final commaIndex = base64Str.indexOf(',');
      if (commaIndex == -1) {
        _hideDownloadDialog();
        return;
      }
      final bytes = base64.decode(base64Str.substring(commaIndex + 1));
      final header = base64Str.substring(0, commaIndex);
      final suggestedName = data['filename']?.toString();
      final meta = _downloadMeta(
        mimeHint: '$header ${suggestedName ?? ''}',
        suggestedName: suggestedName,
      );

      _hideDownloadDialog();
      await _shareDownloadedBytes(
        bytes: bytes,
        filename: meta.filename,
        mimeType: meta.mimeType,
        shareText: meta.shareText,
      );
    } catch (e) {
      _hideDownloadDialog();
      debugPrint('Error processing blob download: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to download file')),
        );
      }
    }
  }

  String? _parseIntentUrl(String url) {
    if (!url.startsWith('intent://')) return null;

    // 1. Try to find browser_fallback_url
    const fallbackKey = 'browser_fallback_url=';
    if (url.contains(fallbackKey)) {
      final startIndex = url.indexOf(fallbackKey) + fallbackKey.length;
      final endIndex = url.indexOf(';', startIndex);
      final encodedFallback = endIndex == -1
          ? url.substring(startIndex)
          : url.substring(startIndex, endIndex);
      final decoded = Uri.decodeComponent(encodedFallback);
      if (decoded.startsWith('http://') || decoded.startsWith('https://')) {
        return decoded;
      }
    }

    // 2. Reconstruct from host/path
    final hashIndex = url.indexOf('#');
    final uriPart = hashIndex == -1 ? url.substring(9) : url.substring(9, hashIndex);

    String scheme = 'https';
    if (url.contains('scheme=')) {
      final schemeStart = url.indexOf('scheme=') + 7;
      final schemeEnd = url.indexOf(';', schemeStart);
      scheme = schemeEnd == -1
          ? url.substring(schemeStart)
          : url.substring(schemeStart, schemeEnd);
    }

    return '$scheme://$uriPart';
  }

  Future<void> _launchExternal(Uri uri) async {
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        debugPrint('Could not launch external URL: $uri');
      }
    } catch (e) {
      debugPrint('Error launching external URL: $e');
    }
  }

  void _onRazorpayRequest(JavaScriptMessage message) {
    final payload = message.message.trim();
    if (payload.isEmpty) return;

    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) {
        throw const FormatException('Invalid Razorpay payload');
      }
      final options = Map<String, dynamic>.from(decoded);
      final handlerId = options.remove('__handlerId');
      _openNativeRazorpay(
        options,
        handlerId: handlerId?.toString(),
      );
    } catch (error) {
      debugPrint('Invalid Razorpay options from WebView: $error');
      _sendPaymentResultToWeb(
        status: 'error',
        data: {'message': 'Invalid payment payload'},
      );
    }
  }

  void _openNativeRazorpay(
    Map<String, dynamic> options, {
    String? handlerId,
  }) {
    try {
      _activeHandlerId = handlerId;
      final checkoutOptions = _buildCheckoutOptions(options);
      debugPrint('Opening native Razorpay SDK with options');
      _razorpay.open(checkoutOptions);
    } catch (error) {
      debugPrint('Failed to open native Razorpay: $error');
      _sendPaymentResultToWeb(
        status: 'error',
        data: {'message': 'Unable to open payment gateway'},
        handlerId: handlerId,
      );
    }
  }

  String? _activeHandlerId;

  Map<String, dynamic> _buildCheckoutOptions(Map<String, dynamic> rawOptions) {
    final options = Map<String, dynamic>.from(rawOptions);
    options['name'] = options['name'] ?? 'Stock Spheres';
    options['image'] = _checkoutLogoDataUri ?? _checkoutLogoUrl;

    final prefill = _asStringDynamicMap(options['prefill']);
    if (!prefill.containsKey('contact')) {
      prefill['contact'] = prefill['contact'] ?? '';
    }
    options['prefill'] = prefill;

    options['method'] = {
      'upi': true,
      'card': true,
      'netbanking': true,
      'wallet': true,
    };

    options['config'] = {
      'display': {
        'blocks': {
          'upi': {
            'name': 'Pay using UPI',
            'instruments': [
              {'method': 'upi'},
            ],
          },
          'card': {
            'name': 'Pay using Card',
            'instruments': [
              {'method': 'card'},
            ],
          },
          'netbanking': {
            'name': 'Pay using Netbanking',
            'instruments': [
              {'method': 'netbanking'},
            ],
          },
          'wallet': {
            'name': 'Pay using Wallet',
            'instruments': [
              {'method': 'wallet'},
            ],
          },
        },
        'sequence': ['block.upi', 'block.card', 'block.netbanking', 'block.wallet'],
        'preferences': {
          'show_default_blocks': true,
        },
      },
    };

    options['theme'] = {
      ..._asStringDynamicMap(options['theme']),
      'color': _asStringDynamicMap(options['theme'])['color'] ?? '#7ED321',
    };

    debugPrint('Razorpay checkout options: ${jsonEncode(options)}');
    return options;
  }

  Map<String, dynamic> _asStringDynamicMap(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return <String, dynamic>{};
  }

  void _handlePaymentSuccess(PaymentSuccessResponse response) {
    if (!kIsWeb) {
      _facebookAppEvents.logEvent(
        name: 'purchase_completed',
        parameters: {
          'payment_id': response.paymentId ?? '',
          'order_id': response.orderId ?? '',
        },
      );
    }
    _sendPaymentResultToWeb(
      status: 'success',
      handlerId: _activeHandlerId,
      data: {
        'paymentId': response.paymentId,
        'orderId': response.orderId,
        'signature': response.signature,
      },
    );
    _activeHandlerId = null;
  }

  void _handlePaymentError(PaymentFailureResponse response) {
    _sendPaymentResultToWeb(
      status: 'error',
      handlerId: _activeHandlerId,
      data: {
        'code': response.code,
        'message': response.message,
      },
    );
    _activeHandlerId = null;
  }

  void _handleExternalWallet(ExternalWalletResponse response) {
    _sendPaymentResultToWeb(
      status: 'external_wallet',
      handlerId: _activeHandlerId,
      data: {'walletName': response.walletName},
    );
  }

  Future<void> _sendPaymentResultToWeb({
    required String status,
    required Map<String, dynamic> data,
    String? handlerId,
  }) async {
    final controller = _controller;
    if (controller == null) return;

    final payload = jsonEncode({
      'status': status,
      'handlerId': handlerId,
      'data': data,
    });
    final escapedPayload = jsonEncode(payload);

    final script = '''
      (function () {
        const event = new CustomEvent('nativeRazorpayResult', {
          detail: JSON.parse($escapedPayload)
        });
        window.dispatchEvent(event);
      })();
    ''';

    await controller.runJavaScript(script);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    if (controller == null) {
      return Scaffold(
        body: _showErrorScreen
            ? _LoadErrorScreen(
                isOffline: _isOffline,
                onRetry: _onRetryNetworkPressed,
              )
            : const Center(child: CircularProgressIndicator()),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_showErrorScreen) {
          SystemNavigator.pop();
          return;
        }
        if (await controller.canGoBack()) {
          await controller.goBack();
        } else if (context.mounted) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              WebViewWidget(controller: controller),
              if (_isLoading &&
                  _loadProgress > 0 &&
                  !_showErrorScreen &&
                  !_isRetrying &&
                  _didLoadSuccessfully)
                Align(
                  alignment: Alignment.topCenter,
                  child: LinearProgressIndicator(
                    value: _loadProgress / 100,
                    minHeight: 3,
                    backgroundColor: Colors.transparent,
                    color: const Color(0xFF7ED321),
                  ),
                ),
              if (_showErrorScreen)
                Positioned.fill(
                  child: _LoadErrorScreen(
                    isOffline: _isOffline,
                    onRetry: _onRetryNetworkPressed,
                  ),
                )
              else if (_isRetrying || !_didLoadSuccessfully)
                const Positioned.fill(
                  child: ColoredBox(
                    color: Color(0xFF0A192F),
                    child: Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF7ED321),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadErrorScreen extends StatelessWidget {
  const _LoadErrorScreen({
    required this.onRetry,
    required this.isOffline,
  });

  final Future<void> Function() onRetry;
  final bool isOffline;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF0A192F),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isOffline
                        ? Icons.wifi_off_rounded
                        : Icons.cloud_off_rounded,
                    size: 44,
                    color: const Color(0xFF7ED321),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  isOffline ? 'No Internet Connection' : 'Unable to load page',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  isOffline
                      ? 'Please check your mobile data or Wi‑Fi and try again.'
                      : 'Please check your connection and try again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.75),
                    fontSize: 15,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      onRetry();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF7ED321),
                      foregroundColor: const Color(0xFF0A192F),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Retry',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
