// DynuclearVolume — Notifications and Siri get louder in loud rooms, quieter in quiet ones.
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

//%hook SomeClass
//- (void)someMethod {
//    NSLog(@"[DynuclearVolume] someMethod");
//    %orig;
//}
//%end

%ctor {
    NSLog(@"[DynuclearVolume] loaded into %@ (pid %d)",
          [NSProcessInfo processInfo].processName,
          [[NSProcessInfo processInfo] processIdentifier]);
}
