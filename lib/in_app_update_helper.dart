import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:url_launcher/url_launcher.dart';

const _androidPackageId = 'com.stocksphere.app';
const _playStoreWebUrl =
    'https://play.google.com/store/apps/details?id=$_androidPackageId';
const _playStoreMarketUrl = 'market://details?id=$_androidPackageId';

/// Checks Play Store for a newer version and blocks the app until the user
/// updates or closes the app.
class InAppUpdateHelper {
  InAppUpdateHelper._();

  static bool _dialogOpen = false;

  static Future<void> checkAndPrompt(BuildContext context) async {
    if (kIsWeb || !Platform.isAndroid) return;
    if (_dialogOpen || !context.mounted) return;

    try {
      final info = await InAppUpdate.checkForUpdate();
      if (info.updateAvailability != UpdateAvailability.updateAvailable) {
        return;
      }
      if (!context.mounted) return;
      await _showForceUpdateDialog(context, info);
    } catch (e) {
      debugPrint('In-app update check failed: $e');
    }
  }

  static Future<void> _showForceUpdateDialog(
    BuildContext context,
    AppUpdateInfo info,
  ) async {
    if (_dialogOpen) return;
    _dialogOpen = true;

    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return PopScope(
            canPop: false,
            child: AlertDialog(
              backgroundColor: const Color(0xFF0A192F),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Text(
                'App Update',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              content: const Text(
                'Play Store par nayi version available hai.\nKripya app update kijiye.',
                style: TextStyle(
                  color: Colors.white70,
                  height: 1.4,
                ),
              ),
              actionsAlignment: MainAxisAlignment.spaceBetween,
              actions: [
                TextButton(
                  onPressed: () {
                    SystemNavigator.pop();
                  },
                  child: const Text(
                    'Close App',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
                FilledButton(
                  onPressed: () => _startUpdate(dialogContext, info),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF7ED321),
                    foregroundColor: const Color(0xFF0A192F),
                  ),
                  child: const Text(
                    'Update',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          );
        },
      );
    } finally {
      _dialogOpen = false;
    }
  }

  static Future<void> _startUpdate(
    BuildContext context,
    AppUpdateInfo info,
  ) async {
    try {
      if (info.immediateUpdateAllowed) {
        final result = await InAppUpdate.performImmediateUpdate();
        if (result == AppUpdateResult.success) return;
        // User cancelled Play's update screen — close the app.
        SystemNavigator.pop();
        return;
      }
    } catch (e) {
      debugPrint('Immediate in-app update failed: $e');
    }

    await _openPlayStore();
  }

  static Future<void> _openPlayStore() async {
    final market = Uri.parse(_playStoreMarketUrl);
    final web = Uri.parse(_playStoreWebUrl);
    try {
      final launched = await launchUrl(
        market,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        await launchUrl(web, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      await launchUrl(web, mode: LaunchMode.externalApplication);
    }
  }
}
