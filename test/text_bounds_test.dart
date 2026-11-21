import 'dart:convert';

import 'package:dont_forget/services/app_update_service.dart';
import 'package:dont_forget/services/multi_agent_service.dart';
import 'package:dont_forget/services/text_bounds.dart';
import 'package:dont_forget/services/windows_toast.dart';
import 'package:flutter_test/flutter_test.dart';

bool _hasUnpairedSurrogate(String text) {
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (i + 1 >= text.length) return true;
      final next = text.codeUnitAt(i + 1);
      if (next < 0xDC00 || next > 0xDFFF) return true;
      i++;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      return true;
    }
  }
  return false;
}

void main() {
  test('truncateRunes never splits UTF-16 surrogate pairs', () {
    final text = 'A${'😀' * 10}Z';
    expect(truncateRunes(text, 5, suffix: '...'), 'A${'😀' * 4}...');
    expect(_hasUnpairedSurrogate(truncateRunes(text, 5, suffix: '...')), isFalse);
    expect(truncateRunes(text, 12), text);
    expect(truncateRunes(text, 0, suffix: '...'), '...');
    expect(truncateRunes('', 0, suffix: '...'), '');
  });

  test('truncateUtf16Safe enforces max code units without unpaired surrogates', () {
    final text = 'A${'🚀' * 95}'; // 1 + 190 = 191 UTF-16 code units
    final clipped = truncateUtf16Safe(text, 180);
    expect(clipped.length, 179); // backs off 1 unit cleanly before splitting 🚀
    expect(_hasUnpairedSurrogate(clipped), isFalse);
    expect(truncateUtf16Safe('😀', 1), '');
    expect(truncateUtf16Safe('😀😀', 4), '😀😀');
  });

  test('MultiAgentService offline macroTitle preserves valid UTF-16 around boundary', () async {
    final service = MultiAgentService();
    final goal = '${'a' * 24}😀额外目标计划';
    final plan = await service.executePipeline(goal);
    expect(_hasUnpairedSurrogate(plan.macroGoalTitle), isFalse);
    expect(plan.macroGoalTitle, '${'a' * 24}😀...');
  });

  test('AppUpdateService bounds long emoji release notes without invalid UTF-16', () async {
    final notes = '${'b' * 31999}${'😀' * 20}';
    final service = AppUpdateService(
      fetch: (uri, limit) async {
        expect(uri, AppUpdateService.latestUri);
        return ReleaseHttpResponse(
          200,
          utf8.encode(
            jsonEncode({
              'tag_name': 'v1.8.19',
              'html_url': '$appReleasesUrl/tag/v1.8.19',
              'draft': false,
              'prerelease': false,
              'body': notes,
              'assets': [
                {
                  'name': 'DontForget_Setup_v1.8.19.exe',
                  'state': 'uploaded',
                  'size': 123,
                  'browser_download_url': 'https://example.invalid/ignore',
                },
              ],
            }),
          ),
        );
      },
    );
    final result = await service.check(
      InstalledAppInfo(name: 'DontForget', version: '1.8.18', buildNumber: '89'),
    );
    expect(_hasUnpairedSurrogate(result.release.notes), isFalse);
    expect(result.release.notes.runes.length, 32000);
  });

  test('WindowsToast script preserves valid UTF-16 at body limit', () {
    final longBody = '${'c' * (WindowsToast.maxBodyLength - 1)}😀tail';
    final script = WindowsToast.script(title: 'Reminder', body: longBody);
    expect(_hasUnpairedSurrogate(script), isFalse);
  });
}
