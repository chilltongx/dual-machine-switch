#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ColorSync/ColorSync.h>
#include <dlfcn.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/sysctl.h>

typedef CGError (*SetEnabled)(CGDisplayConfigRef, CGDirectDisplayID, bool);
static SetEnabled setEnabled;
static NSString *root;
static NSString *externalUUID;
static NSString *bootSession(void) {
    char value[128]={0};size_t size=sizeof(value);
    return sysctlbyname("kern.bootsessionuuid",value,&size,NULL,0)==0 ? @(value) : @"";
}

static void require(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"DisplayProfile" reason:message userInfo:nil];
}
static void check(CGError error, NSString *stage) {
    require(error == kCGErrorSuccess, [NSString stringWithFormat:@"%@: CGError %d", stage, error]);
}
static NSString *uuid(CGDirectDisplayID display) {
    CFUUIDRef value = CGDisplayCreateUUIDFromDisplayID(display);
    if (!value) return @"";
    NSString *result = CFBridgingRelease(CFUUIDCreateString(NULL, value));
    CFRelease(value); return result;
}
static CGDirectDisplayID fromUUID(NSString *value) {
    if (!value.length) return 0;
    CFUUIDRef identifier = CFUUIDCreateFromString(NULL, (__bridge CFStringRef)value);
    if (!identifier) return 0;
    CGDirectDisplayID result = CGDisplayGetDisplayIDFromUUID(identifier);
    CFRelease(identifier); return result;
}
static BOOL enabled(CGDirectDisplayID display) {
    return display && (CGDisplayIsActive(display) || CGDisplayIsInMirrorSet(display));
}
static NSDictionary *readJSON(NSString *name) {
    NSData *data = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:name]];
    id result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [result isKindOfClass:[NSDictionary class]] ? result : nil;
}
static void writeJSON(NSString *name, NSDictionary *value) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:&error];
    require(data && [data writeToFile:[root stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:&error], error.localizedDescription ?: @"无法保存显示配置");
}
static void logLine(NSString *value) {
    NSString *path = [root stringByAppendingPathComponent:@"mac-display.log"];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], value];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    [file seekToEndOfFile]; [file writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [file closeFile];
}
static NSDictionary *status(void) {
    CGDirectDisplayID displays[16]; uint32_t count=0;
    check(CGGetOnlineDisplayList(16,displays,&count), @"读取显示器");
    NSMutableArray *items=[NSMutableArray array];
    for (uint32_t i=0;i<count;i++) {
        CGDirectDisplayID d=displays[i]; CGRect bounds=CGDisplayBounds(d);
        [items addObject:@{@"id":@(d),@"uuid":uuid(d),@"builtin":@(CGDisplayIsBuiltin(d)!=0),@"enabled":@(enabled(d)),@"active":@(CGDisplayIsActive(d)!=0),@"main":@(CGMainDisplayID()==d),@"mirrors":@(CGDisplayMirrorsDisplay(d)),@"x":@(bounds.origin.x),@"y":@(bounds.origin.y),@"width":@(bounds.size.width),@"height":@(bounds.size.height)}];
    }
    return @{@"mainDisplay":@(CGMainDisplayID()),@"displays":items};
}
static void transaction(void (^configure)(CGDisplayConfigRef)) {
    CGDisplayConfigRef config=NULL;
    check(CGBeginDisplayConfiguration(&config), @"开始显示配置");
    @try { configure(config); }
    @catch (NSException *error) { CGCancelDisplayConfiguration(config); @throw error; }
    check(CGCompleteDisplayConfiguration(config,kCGConfigureForSession), @"应用显示配置");
}
static void applyProfile(NSString *target) {
    NSDictionary *snapshot=readJSON(@"mac-display-profile.json");
    CGDirectDisplayID builtin=fromUUID(snapshot[@"builtinUUID"]);
    CGDirectDisplayID external=fromUUID(externalUUID);
    if(!external && bootSession().length && [snapshot[@"bootSession"] isEqualToString:bootSession()] && [snapshot[@"externalUUID"] isEqualToString:externalUUID]) external=[snapshot[@"externalID"] unsignedIntValue];
    if (!builtin || !CGDisplayIsBuiltin(builtin)) {
        for (NSDictionary *item in status()[@"displays"]) if ([item[@"builtin"] boolValue]) builtin=[item[@"id"] unsignedIntValue];
    }
    require(builtin && CGDisplayIsOnline(builtin), @"Mac 内置屏幕不可用，请先打开笔记本屏幕");
    require(setEnabled!=NULL, @"当前 macOS 不提供显示器启停接口");
    BOOL windows=[target isEqualToString:@"windows"];
    if (windows) {
        if (external && enabled(external) && (!snapshot || [readJSON(@"mac-display-state.json")[@"target"] isEqualToString:@"mac"])) {
            CGDisplayModeRef mode=CGDisplayCopyDisplayMode(external);
            snapshot=@{@"builtinUUID":uuid(builtin),@"externalUUID":externalUUID,@"externalID":@(external),@"bootSession":bootSession(),@"mirrored":@(CGDisplayIsInMirrorSet(builtin) && CGDisplayIsInMirrorSet(external)),@"externalMode":@(mode?CGDisplayModeGetIODisplayModeID(mode):0)};
            if(mode) CGDisplayModeRelease(mode);
            writeJSON(@"mac-display-profile.json",snapshot);
        }
        if (external && enabled(external)) {
            transaction(^(CGDisplayConfigRef config) {
                if(CGDisplayMirrorsDisplay(builtin)) check(CGConfigureDisplayMirrorOfDisplay(config,builtin,0), @"解除内置屏幕镜像");
                if(CGDisplayMirrorsDisplay(external)) check(CGConfigureDisplayMirrorOfDisplay(config,external,0), @"解除外接屏镜像");
            });
            transaction(^(CGDisplayConfigRef config) {
                check(CGConfigureDisplayOrigin(config,builtin,0,0), @"内置屏幕设为主屏");
                check(CGConfigureDisplayOrigin(config,external,(int32_t)CGDisplayBounds(builtin).size.width,0), @"移开外接屏原点");
            });
            transaction(^(CGDisplayConfigRef config) {
                check(setEnabled(config,external,false), @"停用 Mac 外接显示输出");
            });
        }
        for(int i=0;i<30 && (enabled(external) || CGMainDisplayID()!=builtin);i++) usleep(100000);
        require(!enabled(external) && CGDisplayIsActive(builtin) && CGMainDisplayID()==builtin, @"系统未确认仅使用内置屏幕");
    } else {
        require(external!=0, @"系统找不到 LECOO，请确认 HDMI 仍插在 Mac 上");
        NSDictionary *preferences=readJSON(@"mac-display-preferences.json");
        BOOL mirrored=preferences[@"mirrored"] ? [preferences[@"mirrored"] boolValue] : (snapshot ? [snapshot[@"mirrored"] boolValue] : NO);
        BOOL layoutMatches=mirrored ? CGDisplayMirrorsDisplay(builtin)==external : (CGDisplayIsActive(builtin) && !CGDisplayIsInMirrorSet(builtin) && !CGDisplayIsInMirrorSet(external));
        if(enabled(external) && CGMainDisplayID()==external && layoutMatches) {
            writeJSON(@"mac-display-state.json",@{@"target":target,@"verified":@YES});
            logLine(@"profile=mac already restored"); return;
        }
        if (!enabled(external)) {
            transaction(^(CGDisplayConfigRef config) {check(setEnabled(config,external,true), @"重新启用 Mac 外接显示输出");});
            usleep(500000);
        }
        if(CGDisplayMirrorsDisplay(builtin) || CGDisplayMirrorsDisplay(external)) {
            transaction(^(CGDisplayConfigRef config) {
                if(CGDisplayMirrorsDisplay(builtin)) check(CGConfigureDisplayMirrorOfDisplay(config,builtin,0), @"解除原镜像布局");
                if(CGDisplayMirrorsDisplay(external)) check(CGConfigureDisplayMirrorOfDisplay(config,external,0), @"解除原外接镜像");
            });
        }
        transaction(^(CGDisplayConfigRef config) {
                check(CGConfigureDisplayOrigin(config,external,0,0), @"LECOO 设为主屏");
                check(CGConfigureDisplayOrigin(config,builtin,(int32_t)CGDisplayBounds(external).size.width,0), @"安排内置屏幕");
        });
        if(mirrored) {
            transaction(^(CGDisplayConfigRef config) {
                check(CGConfigureDisplayMirrorOfDisplay(config,builtin,external), @"恢复镜像显示");
            });
        }
        for(int i=0;i<30 && (!enabled(external) || CGMainDisplayID()!=external);i++) usleep(100000);
        require(enabled(external) && CGMainDisplayID()==external, @"系统未确认外接屏已恢复为主屏");
        if(mirrored) require(CGDisplayMirrorsDisplay(builtin)==external,@"系统未确认镜像已恢复");
        else require(CGDisplayIsActive(builtin) && !CGDisplayIsInMirrorSet(builtin) && !CGDisplayIsInMirrorSet(external),@"系统未确认扩展桌面已恢复");
    }
    writeJSON(@"mac-display-state.json",@{@"target":target,@"verified":@YES});
    logLine([NSString stringWithFormat:@"profile=%@ verified %@",target,status()]);
}

int main(int argc,const char **argv) {
    @autoreleasepool {
        root=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MonitorSwitch"];
        [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        setEnabled=(SetEnabled)dlsym(RTLD_DEFAULT,"CGSConfigureDisplayEnabled");
        int lock=-1;
        NSString *target=argc==2 ? @(argv[1]) : @"status";
        @try {
            require([@[@"status",@"windows",@"mac"] containsObject:target],@"参数只能为 status、windows 或 mac");
            // Initialize WindowServer's display client before ColorSync UUID lookup.
            (void)status();
            if (![target isEqualToString:@"status"]) {
                id configured=readJSON(@"config.json")[@"displayUUID"];
                if(![configured isKindOfClass:[NSString class]] || ![configured length]) configured=readJSON(@"mac-display-profile.json")[@"externalUUID"];
                require([configured isKindOfClass:[NSString class]] && [configured length], @"请在 config.json 中配置 displayUUID（可用 status 查询）");
                externalUUID=configured;
                writeJSON(@"mac-display-request.json",@{@"target":target});
                lock=open([[root stringByAppendingPathComponent:@"mac-display.lock"] fileSystemRepresentation],O_CREAT|O_RDWR,0600);
                require(lock>=0 && flock(lock,LOCK_EX)==0,@"无法锁定显示配置");
                for(int i=0;i<3;i++) {
                    NSString *latest=readJSON(@"mac-display-request.json")[@"target"];
                    applyProfile(latest);
                    if([latest isEqualToString:readJSON(@"mac-display-request.json")[@"target"]]) break;
                }
            }
            NSData *json=[NSJSONSerialization dataWithJSONObject:status() options:NSJSONWritingPrettyPrinted error:nil];
            puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
            if(lock>=0) {flock(lock,LOCK_UN);close(lock);}
            return 0;
        } @catch(NSException *error) {
            logLine([NSString stringWithFormat:@"ERROR %@",error.reason]);
            if(![target isEqualToString:@"status"]) {
                NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"target":target,@"verified":@NO,@"error":error.reason ?: @"显示配置失败"} options:0 error:nil];
                [data writeToFile:[root stringByAppendingPathComponent:@"mac-display-state.json"] atomically:YES];
            }
            fprintf(stderr,"%s\n",error.reason.UTF8String);
            if(lock>=0) {flock(lock,LOCK_UN);close(lock);}
            return 1;
        }
    }
}
