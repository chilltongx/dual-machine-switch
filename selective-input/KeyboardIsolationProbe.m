#import <AppKit/AppKit.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>

@interface Probe : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property NSTextField *field;
@property NSTextField *label;
@property NSUInteger rawCount;
@property IOHIDManagerRef manager;
@property IOHIDEventSystemClientRef system;
@property IOHIDServiceClientRef service;
@property CFTypeRef original;
@property BOOL restored;
@end
static void valueCallback(void *context,IOReturn result,void *sender,IOHIDValueRef value) {
    (void)result;(void)sender;
    Probe *probe=(__bridge Probe*)context;
    IOHIDElementRef element=IOHIDValueGetElement(value);
    if(IOHIDElementGetUsagePage(element)==7 && IOHIDElementGetUsage(element)==4 && IOHIDValueGetIntegerValue(value)) {
        probe.rawCount++;
        probe.label.stringValue=[NSString stringWithFormat:@"收到外接键盘的原始 A 按键：%lu 次",(unsigned long)probe.rawCount];
    }
}
@implementation Probe
- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;
    self.system=IOHIDEventSystemClientCreateSimpleClient(NULL);
    CFArrayRef services=IOHIDEventSystemClientCopyServices(self.system);
    for(CFIndex i=0;i<CFArrayGetCount(services);i++) {
        IOHIDServiceClientRef service=(IOHIDServiceClientRef)CFArrayGetValueAtIndex(services,i);
        NSString *product=CFBridgingRelease(IOHIDServiceClientCopyProperty(service,CFSTR(kIOHIDProductKey)));
        NSString *transport=CFBridgingRelease(IOHIDServiceClientCopyProperty(service,CFSTR(kIOHIDTransportKey)));
        if([product hasPrefix:@"Flow84-L@Lofree"] && [transport containsString:@"Bluetooth"] && IOHIDServiceClientConformsTo(service,1,6)) {self.service=(IOHIDServiceClientRef)CFRetain(service);break;}
    }
    CFRelease(services);
    if(!self.service) {fprintf(stderr,"External keyboard service not found\n");[NSApp terminate:nil];return;}
    self.original=IOHIDServiceClientCopyProperty(self.service,CFSTR("UserKeyMapping"));
    NSMutableArray *mapping=[NSMutableArray array];
    if(self.original && CFGetTypeID(self.original)==CFArrayGetTypeID()) {
        for(NSDictionary *item in (__bridge NSArray*)self.original) if([item[@"HIDKeyboardModifierMappingSrc"] unsignedLongLongValue]!=0x700000004ULL) [mapping addObject:item];
    }
    [mapping addObject:@{@"HIDKeyboardModifierMappingSrc":@(0x700000004ULL),@"HIDKeyboardModifierMappingDst":@0}];
    if(!IOHIDServiceClientSetProperty(self.service,CFSTR("UserKeyMapping"),(__bridge CFTypeRef)mapping)) {fprintf(stderr,"Cannot apply per-device mapping\n");[NSApp terminate:nil];return;}
    self.manager=IOHIDManagerCreate(NULL,kIOHIDOptionsTypeNone);
    NSDictionary *match=@{@kIOHIDVendorIDKey:@1452,@kIOHIDProductIDKey:@591,@kIOHIDTransportKey:@"Bluetooth Low Energy"};
    IOHIDManagerSetDeviceMatching(self.manager,(__bridge CFDictionaryRef)match);
    IOHIDManagerRegisterInputValueCallback(self.manager,valueCallback,(__bridge void*)self);
    IOHIDManagerScheduleWithRunLoop(self.manager,CFRunLoopGetCurrent(),kCFRunLoopDefaultMode);
    IOReturn result=IOHIDManagerOpen(self.manager,kIOHIDOptionsTypeNone);
    if(result) {fprintf(stderr,"Cannot open HID: 0x%x\n",result);[self finish:nil];return;}
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,560,300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"外接键盘隔离测试";[self.window center];
    NSTextField *instructions=[NSTextField wrappingLabelWithString:@"请先用外接 Lofree 键盘按 A 三次，再用 Mac 自带键盘输入 B。\n预期：外接 A 计数增加，但输入框只出现内置键盘的 B。\n仅临时屏蔽外接键盘的 A，90 秒后自动恢复。"];
    instructions.frame=NSMakeRect(24,178,512,95);[self.window.contentView addSubview:instructions];
    self.label=[NSTextField labelWithString:@"收到外接键盘的原始 A 按键：0 次"];self.label.frame=NSMakeRect(24,138,512,24);[self.window.contentView addSubview:self.label];
    self.field=[[NSTextField alloc] initWithFrame:NSMakeRect(24,86,512,36)];self.field.placeholderString=@"在这里测试";[self.window.contentView addSubview:self.field];
    NSButton *done=[NSButton buttonWithTitle:@"完成并恢复" target:self action:@selector(finish:)];done.frame=NSMakeRect(24,28,150,32);[self.window.contentView addSubview:done];
    [self.window makeKeyAndOrderFront:nil];[self.window makeFirstResponder:self.field];[NSApp activateIgnoringOtherApps:YES];
    [NSTimer scheduledTimerWithTimeInterval:90 target:self selector:@selector(finish:) userInfo:nil repeats:NO];
}
- (void)restore {
    if(self.restored) return;self.restored=YES;
    if(self.service) {
        IOHIDServiceClientSetProperty(self.service,CFSTR("UserKeyMapping"),self.original ?: (__bridge CFTypeRef)@[]);
        CFRelease(self.service);self.service=NULL;
    }
    if(self.original) {CFRelease(self.original);self.original=NULL;}
    if(self.manager) {IOHIDManagerClose(self.manager,kIOHIDOptionsTypeNone);CFRelease(self.manager);self.manager=NULL;}
}
- (void)finish:(id)sender {
    (void)sender;
    [self restore];
    NSString *text=self.field.stringValue.lowercaseString ?: @"";
    NSDictionary *result=@{@"externalRawA":@(self.rawCount),@"localA":@([[text componentsSeparatedByString:@"a"] count]-1),@"localB":@([[text componentsSeparatedByString:@"b"] count]-1),@"mappingRestored":@YES};
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MonitorSwitch/keyboard-isolation-probe.json"] atomically:YES];
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);[NSApp terminate:nil];
}
- (void)applicationWillTerminate:(NSNotification*)notification {(void)notification;[self restore];}
@end
int main(void) {@autoreleasepool {NSApplication *app=[NSApplication sharedApplication];Probe *probe=[Probe new];app.delegate=probe;[app setActivationPolicy:NSApplicationActivationPolicyRegular];[app run];}}
