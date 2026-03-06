#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The resource bundle ID.
static NSString * const ACBundleID AC_SWIFT_PRIVATE = @"com.maxxu.picturetrack";

/// The "LaunchScreenColor" asset catalog color resource.
static NSString * const ACColorNameLaunchScreenColor AC_SWIFT_PRIVATE = @"LaunchScreenColor";

/// The "LaunchScreenImage" asset catalog image resource.
static NSString * const ACImageNameLaunchScreenImage AC_SWIFT_PRIVATE = @"LaunchScreenImage";

/// The "test1" asset catalog image resource.
static NSString * const ACImageNameTest1 AC_SWIFT_PRIVATE = @"test1";

/// The "test2" asset catalog image resource.
static NSString * const ACImageNameTest2 AC_SWIFT_PRIVATE = @"test2";

/// The "test3" asset catalog image resource.
static NSString * const ACImageNameTest3 AC_SWIFT_PRIVATE = @"test3";

/// The "test4" asset catalog image resource.
static NSString * const ACImageNameTest4 AC_SWIFT_PRIVATE = @"test4";

/// The "test5" asset catalog image resource.
static NSString * const ACImageNameTest5 AC_SWIFT_PRIVATE = @"test5";

#undef AC_SWIFT_PRIVATE
