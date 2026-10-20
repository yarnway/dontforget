import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Fingerprints of credentials previously bundled in the application.
/// Keep only one-way fingerprints so migrations can remove these exact keys.
bool isLegacyBundledCredential(String value) {
  const fingerprints = {
    'bb52c2921c7886a9908980b4eece6160a3b712a4e40e8b6f330c13f0397049cf',
    '9bb9979f1cb6e021991e7782476dd946b711ed048974a5fd9c37ef704db1428a',
  };
  return fingerprints.contains(sha256.convert(utf8.encode(value)).toString());
}
