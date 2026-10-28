/// An opaque OS-store lookup identifier, never a usable API credential.
const credentialReferencePrefix = '@dontforget-vault-v1:';
bool isCredentialReference(Object? value) =>
    value is String &&
    RegExp(r'^@dontforget-vault-v1:[a-f0-9-]{36}$').hasMatch(value);
