#pragma once
#include <Security/Security.h>

// The file-based login keychain does not honor LAContext interaction settings.
static inline OSStatus FoldDayReadKeychainWithoutPrompt(CFDictionaryRef query, CFTypeRef *result) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    Boolean previous;
    OSStatus status = SecKeychainGetUserInteractionAllowed(&previous);
    if (status != errSecSuccess) return status;
    status = SecKeychainSetUserInteractionAllowed(false);
    if (status != errSecSuccess) return status;
    status = SecItemCopyMatching(query, result);
    SecKeychainSetUserInteractionAllowed(previous);
    return status;
#pragma clang diagnostic pop
}
