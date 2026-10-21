#include "KeychainInteractionCompatibility.h"
#include <Security/Security.h>

int32_t FixtureDisableLegacyKeychainInteraction(void) {
    // Apple LAContext.h documents interactionNotAllowed as equivalent to
    // kSecUseNoAuthenticationUI; SecItem.h limits that option to the Data
    // Protection keychain and warns that legacy items can still display UI.
    // Keep this public compatibility API for the fixture's traditional SecItem
    // path. The setting affects interaction, not an item's ACL or stored data.
    // https://developer.apple.com/documentation/localauthentication/lacontext/interactionnotallowed
    // https://developer.apple.com/documentation/security/ksecusenoauthenticationui
    // https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSStatus status = SecKeychainSetUserInteractionAllowed(false);
#pragma clang diagnostic pop
    return status;
}
