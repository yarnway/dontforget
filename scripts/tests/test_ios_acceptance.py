import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import prepare_ios_acceptance as ios_acc


class TestIOSAcceptance(unittest.TestCase):
    def setUp(self):
        self.sample_pbxproj = """
// !$*UTF8*$!
{
    objects = {
        F54B97FACE6560E6F2E2A95C /* ReminderActivity */ = {
            buildSettings = {
                INFOPLIST_FILE = ReminderActivity/Info.plist;
                PRODUCT_BUNDLE_IDENTIFIER = com.yarnway.dontforget.ReminderActivity;
            };
        };
        97C146FD1CF9000F007C117D /* Runner */ = {
            buildSettings = {
                INFOPLIST_FILE = Runner/Info.plist;
                PRODUCT_BUNDLE_IDENTIFIER = com.yarnway.dontforget;
            };
        };
        331C80D4294CF70F00263BE5 /* RunnerTests */ = {
            buildSettings = {
                PRODUCT_BUNDLE_IDENTIFIER = com.yarnway.dontforget.RunnerTests;
                TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Runner.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Runner";
            };
        };
    };
}
"""
        self.sample_plist_dict = {
            'CFBundleDisplayName': '别忘了',
            'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
            'CFBundleURLTypes': [
                {
                    'CFBundleURLSchemes': ['dontforget-live', 'dontforget']
                }
            ],
        }
        self.sample_plist = plistlib.dumps(self.sample_plist_dict)

    def test_run_id_validation(self):
        valid = ['test1', 'qa-run-42', 'acceptance-2026', 'p1current28']
        for vid in valid:
            self.assertEqual(ios_acc.validate_run_id(vid), vid)

        invalid = ['', '-bad', 'BadCapital', 'invalid_underscore', 'a' * 50]
        for ivid in invalid:
            with self.assertRaises(ValueError):
                ios_acc.validate_run_id(ivid)

    def test_rewrite_and_revert_pbxproj(self):
        run_id = 'test-run-1'
        rewritten = ios_acc.rewrite_pbxproj(self.sample_pbxproj, run_id)

        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = com.yarnway.dontforget.acceptance.test-run-1;', rewritten)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = com.yarnway.dontforget.acceptance.test-run-1.ReminderActivity;', rewritten)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = com.yarnway.dontforget.acceptance.test-run-1.RunnerTests;', rewritten)
        self.assertNotIn('PRODUCT_BUNDLE_IDENTIFIER = com.yarnway.dontforget;', rewritten)

        # Test idempotent rewrites with another run_id without nesting
        second_run = ios_acc.rewrite_pbxproj(rewritten, 'run2')
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = com.yarnway.dontforget.acceptance.run2;', second_run)
        self.assertNotIn('test-run-1', second_run)

        # Revert back
        reverted = ios_acc.revert_pbxproj(second_run)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = com.yarnway.dontforget;', reverted)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = com.yarnway.dontforget.ReminderActivity;', reverted)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = com.yarnway.dontforget.RunnerTests;', reverted)
        self.assertNotIn('acceptance', reverted)

    def test_rewrite_and_revert_info_plist(self):
        run_id = 'test-run-1'
        rewritten_bytes = ios_acc.rewrite_info_plist(self.sample_plist, run_id)
        data = plistlib.loads(rewritten_bytes)

        self.assertEqual(data['CFBundleDisplayName'], '别忘了·验收 test-run-1')
        schemes = data['CFBundleURLTypes'][0]['CFBundleURLSchemes']
        self.assertIn('dontforget', schemes)
        self.assertIn('dontforget-live', schemes)
        self.assertIn('dontforget-live-test-run-1', schemes)

        # Revert back
        reverted_bytes = ios_acc.revert_info_plist(rewritten_bytes)
        reverted_data = plistlib.loads(reverted_bytes)
        self.assertEqual(reverted_data['CFBundleDisplayName'], '别忘了')
        rev_schemes = reverted_data['CFBundleURLTypes'][0]['CFBundleURLSchemes']
        self.assertIn('dontforget', rev_schemes)
        self.assertIn('dontforget-live', rev_schemes)
        self.assertNotIn('dontforget-live-test-run-1', rev_schemes)

    def test_prepare_and_revert_workflow_in_directory(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            ios_dir = root / 'ios/Runner.xcodeproj'
            ios_dir.mkdir(parents=True)
            runner_dir = root / 'ios/Runner'
            runner_dir.mkdir(parents=True)

            pbxproj_file = ios_dir / 'project.pbxproj'
            pbxproj_file.write_text(self.sample_pbxproj, encoding='utf-8')
            plist_file = runner_dir / 'Info.plist'
            plist_file.write_bytes(self.sample_plist)

            # Dry run test
            dry_report = ios_acc.prepare(root, 'dry-test', dry_run=True)
            self.assertTrue(dry_report['dry_run'])
            self.assertEqual(pbxproj_file.read_text(encoding='utf-8'), self.sample_pbxproj)

            # Actual prepare test
            report = ios_acc.prepare(root, 'real-test', dry_run=False)
            self.assertFalse(report['dry_run'])
            self.assertEqual(report['host_bundle_id'], 'com.yarnway.dontforget.acceptance.real-test')
            self.assertIn('com.yarnway.dontforget.acceptance.real-test', pbxproj_file.read_text(encoding='utf-8'))

            # Actual revert test
            revert_report = ios_acc.revert(root, dry_run=False)
            self.assertEqual(revert_report['action'], 'revert')
            self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = com.yarnway.dontforget;', pbxproj_file.read_text(encoding='utf-8'))
            self.assertNotIn('acceptance', pbxproj_file.read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
