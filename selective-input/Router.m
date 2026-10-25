#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include "Router.h"

static NSString *Root(void) {return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MonitorSwitch"];}
static NSString *File(NSString *name) {return [Root() stringByAppendingPathComponent:name];}
static id Read(NSString *name) {NSData *d=[NSData dataWithContentsOfFile:File(name)];return d?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:nil;}
static BOOL Write(NSString *name,id value) {NSData *d=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];BOOL ok=d&&[d writeToFile:File(name) atomically:YES];if(ok)chmod(File(name).fileSystemRepresentation,0600);return ok;}
static void Log(NSString *text) {
    NSString *path=File(@"selective-input.log");if(![[NSFileManager defaultManager] fileExistsAtPath:path])[@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:path];[h seekToEndOfFile];[h writeData:[[NSString stringWithFormat:@"%@ %@\n",[NSDate date],text] dataUsingEncoding:NSUTF8StringEncoding]];[h closeFile];
}
static BOOL Selected(NSString *product,NSString *transport,NSNumber *vendor,NSNumber *pid,NSNumber *builtin) {
    if(builtin.boolValue)return NO;
    return (vendor.intValue==1452&&pid.intValue==591&&[product hasPrefix:@"Flow84-L@Lofree"]&&[transport containsString:@"Bluetooth"])
        ||(vendor.intValue==14073&&pid.intValue==43552&&[product isEqualToString:@"X7 Receiver 8K"]&&[transport isEqualToString:@"USB"]);
}
static id Property(IOHIDServiceClientRef s,NSString *key){return CFBridgingRelease(IOHIDServiceClientCopyProperty(s,(__bridge CFStringRef)key));}
static BOOL SelectedService(IOHIDServiceClientRef s){return Selected(Property(s,@kIOHIDProductKey),Property(s,@kIOHIDTransportKey),Property(s,@kIOHIDVendorIDKey),Property(s,@kIOHIDProductIDKey),Property(s,@"Built-In"));}
static BOOL SelectedDevice(IOHIDDeviceRef d){return Selected((__bridge id)IOHIDDeviceGetProperty(d,CFSTR(kIOHIDProductKey)),(__bridge id)IOHIDDeviceGetProperty(d,CFSTR(kIOHIDTransportKey)),(__bridge id)IOHIDDeviceGetProperty(d,CFSTR(kIOHIDVendorIDKey)),(__bridge id)IOHIDDeviceGetProperty(d,CFSTR(kIOHIDProductIDKey)),(__bridge id)IOHIDDeviceGetProperty(d,CFSTR("Built-In")));}
int RequestSelectiveInputAccess(void) {return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)?1:0;}

int RecoverSelectiveMappings(void) {
    NSArray *backup=Read(@"selective-mapping-backup.json");if(![backup isKindOfClass:[NSArray class]])return 0;
    IOHIDEventSystemClientRef system=IOHIDEventSystemClientCreateSimpleClient(NULL);
    CFArrayRef services=IOHIDEventSystemClientCopyServices(system);int failures=0;
    for(CFIndex i=0;i<CFArrayGetCount(services);i++) {
        IOHIDServiceClientRef s=(IOHIDServiceClientRef)CFArrayGetValueAtIndex(services,i);if(!SelectedService(s))continue;
        NSNumber *registry=(__bridge NSNumber*)IOHIDServiceClientGetRegistryID(s);
        for(NSDictionary *entry in backup) {
            if(![registry isEqual:entry[@"registry"]])continue;
            id current=Property(s,@"UserKeyMapping");
            if([current isEqual:entry[@"blocked"]]) {
                if(!IOHIDServiceClientSetProperty(s,CFSTR("UserKeyMapping"),(__bridge CFTypeRef)entry[@"original"])) failures++;
            } else if(current && ![current isEqual:entry[@"original"]]) {
                // A user or another mapper changed this device; do not overwrite it.
                Log(@"Device mapping changed externally; preserving the newer mapping.");
            }
        }
    }
    CFRelease(services);CFRelease(system);
    if(!failures)[[NSFileManager defaultManager] removeItemAtPath:File(@"selective-mapping-backup.json") error:nil];
    return failures?1:0;
}

@interface Router:NSObject
@property IOHIDManagerRef manager;
@property IOHIDManagerRef keyboardManager;
@property IOHIDManagerRef mouseManager;
@property id activity;
@property NSMutableArray *devices;
@property NSMutableSet *seized;
@property NSMutableSet *pressed;
@property NSMutableDictionary *held;
@property NSMutableArray *frames;
@property NSString *mode;
@property NSString *error;
@property NSString *lastCommand;
@property NSTask *ssh;
@property NSPipe *input;
@property NSPipe *output;
@property NSPipe *errors;
@property NSFileHandle *socketHandle;
@property uint16_t localPort;
@property NSMutableData *received;
@property dispatch_queue_t writer;
@property dispatch_source_t termSignal;
@property dispatch_source_t intSignal;
@property NSInteger generation;
@property NSInteger readyAttempts;
@property NSInteger pendingWrites;
@property BOOL transportReady;
@property long long dx,dy,sx,sy;
@property NSUInteger keyEvents,mouseEvents;
@property NSTimeInterval started,lastHeartbeat,lastStatus,lastPoll;
- (void)stop:(NSString*)reason;
- (void)activate:(NSInteger)generation;
- (void)connectTunnel:(NSInteger)generation;
- (void)receive:(IOHIDValueRef)value;
@end
static void InputValue(void *context,IOReturn result,void *sender,IOHIDValueRef value){(void)sender;if(result==kIOReturnSuccess)[(__bridge Router*)context receive:value];}
static void RemovedDevice(void *context,IOReturn result,void *sender,IOHIDDeviceRef device){(void)result;(void)sender;(void)device;Router *r=(__bridge Router*)context;dispatch_async(dispatch_get_main_queue(),^{if([r.mode isEqualToString:@"windows"])[r stop:@"外接设备断开，已恢复本地控制。"];});}

@implementation Router
- (void)publish {
    Write(@"selective-input-state.json",@{@"mode":self.mode?:@"mac",@"command":self.lastCommand?:@"",@"error":self.error?:@"",@"pid":@(getpid()),@"externalKeyEvents":@(self.keyEvents),@"externalMouseEvents":@(self.mouseEvents),@"builtinDevicesCaptured":@0});
}
- (void)profile:(NSString*)target {
    NSTask *p=[NSTask new];p.executableURL=[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@".local/bin/display-handoff"]];p.arguments=@[target,@"--request-id",self.lastCommand];p.standardOutput=[NSFileHandle fileHandleWithNullDevice];p.standardError=[NSFileHandle fileHandleWithNullDevice];[p launchAndReturnError:nil];
}
- (void)stop:(NSString*)reason {
    BOOL wasRemote=![self.mode isEqualToString:@"mac"];
    self.mode=@"mac";self.error=reason?:@"";self.generation++;self.transportReady=NO;
    [self.frames removeAllObjects];self.dx=self.dy=self.sx=self.sy=0;
    if(self.keyboardManager){IOHIDManagerClose(self.keyboardManager,kIOHIDOptionsTypeNone);IOHIDManagerUnscheduleFromRunLoop(self.keyboardManager,CFRunLoopGetCurrent(),kCFRunLoopDefaultMode);CFRelease(self.keyboardManager);self.keyboardManager=NULL;}
    if(self.mouseManager){IOHIDManagerClose(self.mouseManager,kIOHIDOptionsTypeNone);IOHIDManagerUnscheduleFromRunLoop(self.mouseManager,CFRunLoopGetCurrent(),kCFRunLoopDefaultMode);CFRelease(self.mouseManager);self.mouseManager=NULL;}
    [self.devices removeAllObjects];[self.seized removeAllObjects];[self.pressed removeAllObjects];[self.held removeAllObjects];
    if(RecoverSelectiveMappings()!=0)self.error=@"外接键盘映射恢复失败，请重新连接键盘。内置键盘仍可用。";
    self.output.fileHandleForReading.readabilityHandler=nil;self.errors.fileHandleForReading.readabilityHandler=nil;self.socketHandle.readabilityHandler=nil;
    NSFileHandle *oldInput=self.socketHandle;NSTask *oldSSH=self.ssh;
    if(oldInput)dispatch_async(self.writer,^{@try{[oldInput writeData:[@"r\nq\n" dataUsingEncoding:NSUTF8StringEncoding]];[oldInput closeFile];}@catch(NSException *e){(void)e;}});
    if(oldSSH)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{if(oldSSH.running)[oldSSH terminate];});
    self.ssh=nil;self.input=nil;self.output=nil;self.errors=nil;self.socketHandle=nil;
    if(self.activity){[[NSProcessInfo processInfo] endActivity:self.activity];self.activity=nil;}
    [self publish];
    if(wasRemote && !reason.length)[self profile:@"mac"];
    Log([NSString stringWithFormat:@"local mode; %@",reason?:@"released external devices"]);
}
- (void)start {
    if(![self.mode isEqualToString:@"mac"])return;
    if(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)!=kIOHIDAccessTypeGranted) {
        [self stop:@"请在系统设置的输入监控中允许双机切换，然后重新连接。"];return;
    }
    self.mode=@"connecting";self.error=@"";self.started=[NSDate timeIntervalSinceReferenceDate];self.readyAttempts=0;
    self.activity=[[NSProcessInfo processInfo] beginActivityWithOptions:(NSActivityUserInitiated|NSActivityLatencyCritical) reason:@"Forwarding selected external keyboard and mouse"];
    NSInteger generation=++self.generation;self.received=[NSMutableData data];
    int temporary=socket(AF_INET,SOCK_STREAM,0);struct sockaddr_in address={0};address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);socklen_t length=sizeof(address);
    if(temporary<0||bind(temporary,(struct sockaddr*)&address,sizeof(address))!=0||getsockname(temporary,(struct sockaddr*)&address,&length)!=0){if(temporary>=0)close(temporary);[self stop:@"无法分配本地 SSH 转发端口。"];return;}
    self.localPort=ntohs(address.sin_port);close(temporary);
    self.output=[NSPipe pipe];self.errors=[NSPipe pipe];self.ssh=[NSTask new];
    self.ssh.executableURL=[NSURL fileURLWithPath:@"/usr/bin/ssh"];
    self.ssh.arguments=@[@"-N",@"-T",@"-L",[NSString stringWithFormat:@"127.0.0.1:%u:127.0.0.1:24811",self.localPort],@"-o",@"ExitOnForwardFailure=yes",@"-o",@"BatchMode=yes",@"-o",@"ConnectTimeout=5",@"-o",@"ServerAliveInterval=2",@"-o",@"ServerAliveCountMax=2",@"x-windows"];
    self.ssh.standardInput=[NSFileHandle fileHandleWithNullDevice];self.ssh.standardOutput=self.output;self.ssh.standardError=self.errors;
    __weak Router *weak=self;
    self.output.fileHandleForReading.readabilityHandler=^(NSFileHandle *h){(void)h.availableData;};
    self.errors.fileHandleForReading.readabilityHandler=^(NSFileHandle *h){(void)h.availableData;};
    self.ssh.terminationHandler=^(NSTask *p){(void)p;dispatch_async(dispatch_get_main_queue(),^{Router *r=weak;if(r&&generation==r.generation)[r stop:@"Windows 连接已结束，外接键鼠已恢复本地控制。"];});};
    NSError *error=nil;if(![self.ssh launchAndReturnError:&error]){[self stop:@"无法启动 SSH 连接。"];return;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self connectTunnel:generation];});
    [self publish];
}
- (void)connectTunnel:(NSInteger)generation {
    if(generation!=self.generation)return;
    int fd=socket(AF_INET,SOCK_STREAM,0);struct sockaddr_in address={0};address.sin_family=AF_INET;address.sin_port=htons(self.localPort);address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if(fd<0||connect(fd,(struct sockaddr*)&address,sizeof(address))!=0){if(fd>=0)close(fd);if([NSDate timeIntervalSinceReferenceDate]-self.started<5)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self connectTunnel:generation];});else[self stop:@"SSH 转发未能连接。"];return;}
    int one=1;setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
    self.socketHandle=[[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    NSString *secret=[[NSString stringWithContentsOfFile:File(@"selective-token.txt") encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if(secret.length!=64){[self stop:@"缺少设备转发配对密钥。"];return;}
    __weak Router *weak=self;
    self.socketHandle.readabilityHandler=^(NSFileHandle *h){
        NSData *data=nil;@try{data=h.availableData;}@catch(NSException *e){(void)e;}
        dispatch_async(dispatch_get_main_queue(),^{Router *r=weak;if(!r||generation!=r.generation)return;
            if(!data.length){[r stop:@"Windows 连接已断开，外接键鼠已留在 Mac。"];return;}
            if(r.transportReady)return;
            [r.received appendData:data];if(r.received.length>2048){[r stop:@"Windows 返回了无效握手。"];return;}
            NSString *text=[[NSString alloc] initWithData:r.received encoding:NSUTF8StringEncoding];
            if([text hasPrefix:@"READY"]&&[r.mode isEqualToString:@"connecting"]){r.transportReady=YES;[r activate:generation];}
        });
    };
    @try{[self.socketHandle writeData:[[NSString stringWithFormat:@"HELLO %@\n",secret] dataUsingEncoding:NSUTF8StringEncoding]];}@catch(NSException *e){(void)e;[self stop:@"Windows 配对连接失败。"];}
}
- (BOOL)keysReleased {
    for(id object in self.devices) {
        IOHIDDeviceRef d=(__bridge IOHIDDeviceRef)object;
        NSArray *elements=CFBridgingRelease(IOHIDDeviceCopyMatchingElements(d,NULL,kIOHIDOptionsTypeNone));
        for(id e in elements) {
            IOHIDElementRef element=(__bridge IOHIDElementRef)e;
            uint32_t page=IOHIDElementGetUsagePage(element),usage=IOHIDElementGetUsage(element);
            if(!((page==7&&usage>=4&&usage<=231)||(page==9&&usage>=1&&usage<=5)))continue;
            IOHIDValueRef value=NULL;
            if(IOHIDDeviceGetValue(d,element,&value)==kIOReturnSuccess&&value&&IOHIDValueGetIntegerValue(value)!=0)return NO;
        }
    }
    return YES;
}
- (BOOL)blockKeyboardMappings {
    IOHIDEventSystemClientRef system=IOHIDEventSystemClientCreateSimpleClient(NULL);
    CFArrayRef services=IOHIDEventSystemClientCopyServices(system);NSMutableArray *backup=[NSMutableArray array];
    NSMutableArray *blocked=[NSMutableArray array];
    for(uint64_t u=4;u<=231;u++)[blocked addObject:@{@"HIDKeyboardModifierMappingSrc":@(0x700000000ULL|u),@"HIDKeyboardModifierMappingDst":@0}];
    for(NSNumber *n in @[@0xe2,@0xe9,@0xea,@0xcd,@0xb5,@0xb6,@0xb7]) [blocked addObject:@{@"HIDKeyboardModifierMappingSrc":@(0xc00000000ULL|n.unsignedLongLongValue),@"HIDKeyboardModifierMappingDst":@0}];
    NSMutableArray *toChange=[NSMutableArray array];BOOL foundFlow=NO;
    for(CFIndex i=0;i<CFArrayGetCount(services);i++) {
        IOHIDServiceClientRef s=(IOHIDServiceClientRef)CFArrayGetValueAtIndex(services,i);
        if(!SelectedService(s)||!IOHIDServiceClientConformsTo(s,1,6))continue;
        NSString *product=Property(s,@kIOHIDProductKey);if([product hasPrefix:@"Flow84-L"])foundFlow=YES;
        id original=Property(s,@"UserKeyMapping")?:@[];
        [backup addObject:@{@"registry":(__bridge id)IOHIDServiceClientGetRegistryID(s),@"original":original,@"blocked":blocked}];
        [toChange addObject:(__bridge id)s];
    }
    BOOL okay=foundFlow;
    if(okay) {
        if(!Write(@"selective-mapping-backup.json",backup)){CFRelease(services);CFRelease(system);return NO;}
        for(id object in toChange) {
            IOHIDServiceClientRef s=(__bridge IOHIDServiceClientRef)object;
            if(!IOHIDServiceClientSetProperty(s,CFSTR("UserKeyMapping"),(__bridge CFTypeRef)blocked)||![Property(s,@"UserKeyMapping") isEqual:blocked]){okay=NO;break;}
        }
    }
    CFRelease(services);CFRelease(system);return okay;
}
- (void)activate:(NSInteger)generation {
    if(generation!=self.generation)return;
    if(self.devices.count==0) {
        if(CGEventSourceButtonState(kCGEventSourceStateHIDSystemState,kCGMouseButtonLeft)||CGEventSourceButtonState(kCGEventSourceStateHIDSystemState,kCGMouseButtonRight)) {
            if(++self.readyAttempts>30){[self stop:@"请松开鼠标按键后再切换。"];return;}
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self activate:generation];});return;
        }
        self.keyboardManager=IOHIDManagerCreate(NULL,kIOHIDOptionsTypeNone);
        self.mouseManager=IOHIDManagerCreate(NULL,kIOHIDOptionsTypeNone);
        NSArray *keyMatch=@[@{@kIOHIDVendorIDKey:@1452,@kIOHIDProductIDKey:@591,@kIOHIDProductKey:@"Flow84-L@Lofree ",@kIOHIDTransportKey:@"Bluetooth Low Energy",@kIOHIDPrimaryUsagePageKey:@1,@kIOHIDPrimaryUsageKey:@6},@{@kIOHIDVendorIDKey:@14073,@kIOHIDProductIDKey:@43552,@kIOHIDProductKey:@"X7 Receiver 8K",@kIOHIDTransportKey:@"USB",@kIOHIDPrimaryUsagePageKey:@1,@kIOHIDPrimaryUsageKey:@6}];
        NSArray *mouseMatch=@[@{@kIOHIDVendorIDKey:@14073,@kIOHIDProductIDKey:@43552,@kIOHIDProductKey:@"X7 Receiver 8K",@kIOHIDTransportKey:@"USB",@kIOHIDPrimaryUsagePageKey:@1,@kIOHIDPrimaryUsageKey:@2},@{@kIOHIDVendorIDKey:@14073,@kIOHIDProductIDKey:@43552,@kIOHIDProductKey:@"X7 Receiver 8K",@kIOHIDTransportKey:@"USB",@kIOHIDPrimaryUsagePageKey:@12,@kIOHIDPrimaryUsageKey:@1}];
        IOHIDManagerSetDeviceMatchingMultiple(self.keyboardManager,(__bridge CFArrayRef)keyMatch);
        IOHIDManagerSetDeviceMatchingMultiple(self.mouseManager,(__bridge CFArrayRef)mouseMatch);
        IOHIDManagerRef managers[]={self.keyboardManager,self.mouseManager};
        NSMutableSet *current=[NSMutableSet set];
        for(int i=0;i<2;i++) {
            IOHIDManagerRegisterInputValueCallback(managers[i],InputValue,(__bridge void*)self);
            IOHIDManagerRegisterDeviceRemovalCallback(managers[i],RemovedDevice,(__bridge void*)self);
            IOHIDManagerScheduleWithRunLoop(managers[i],CFRunLoopGetCurrent(),kCFRunLoopDefaultMode);
            if(IOHIDManagerOpen(managers[i],i==1?kIOHIDOptionsTypeSeizeDevice:kIOHIDOptionsTypeNone)!=kIOReturnSuccess){[self stop:@"无法读取选中的外设，请检查输入监控权限。"];return;}
            NSSet *items=CFBridgingRelease(IOHIDManagerCopyDevices(managers[i]));if(items)[current unionSet:items];
        }
        BOOL keyboard=NO,mouse=NO;
        for(id object in current) {
            IOHIDDeviceRef d=(__bridge IOHIDDeviceRef)object;if(!SelectedDevice(d))continue;
            NSNumber *page=(__bridge id)IOHIDDeviceGetProperty(d,CFSTR(kIOHIDPrimaryUsagePageKey));
            NSNumber *usage=(__bridge id)IOHIDDeviceGetProperty(d,CFSTR(kIOHIDPrimaryUsageKey));
            if(!((page.intValue==1&&(usage.intValue==2||usage.intValue==6))||(page.intValue==12&&usage.intValue==1)))continue;
            [self.devices addObject:object];
            NSString *product=(__bridge id)IOHIDDeviceGetProperty(d,CFSTR(kIOHIDProductKey));
            if([product hasPrefix:@"Flow84-L"])keyboard=YES;
            if([product isEqualToString:@"X7 Receiver 8K"]&&page.intValue==1&&usage.intValue==2)mouse=YES;
        }
        if(!keyboard||!mouse){[self stop:@"没有找到 Lofree 键盘和 X7 鼠标，请保持两件外设连接 Mac。"];return;}
    }
    if(![self keysReleased]) {
        if(++self.readyAttempts>30){[self stop:@"请先松开外接键盘和鼠标的按键，再切换。"];return;}
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self activate:generation];});return;
    }
    if(![self blockKeyboardMappings]){[self stop:@"外接键盘隔离未完成，已恢复本地输入。"];return;}
    self.mode=@"windows";self.error=@"";self.lastHeartbeat=0;[self publish];[self profile:@"windows"];Log(@"Forwarding only Lofree and X7; built-in devices untouched.");
}
- (void)receive:(IOHIDValueRef)value {
    if(![self.mode isEqualToString:@"windows"])return;
    IOHIDElementRef element=IOHIDValueGetElement(value);IOHIDDeviceRef device=IOHIDElementGetDevice(element);
    if(!SelectedDevice(device))return;
    uint32_t page=IOHIDElementGetUsagePage(element),usage=IOHIDElementGetUsage(element);CFIndex v=IOHIDValueGetIntegerValue(value);
    if(page==7||(page==12&&usage!=0x238)) {
        if((page==7&&(usage<4||usage>231))||usage>65535)return;
        NSString *token=[NSString stringWithFormat:@"%p:%u:%u",device,page,usage];NSNumber *key=@((page<<16)|usage);
        BOOL down=v!=0,was=[self.pressed containsObject:token];if(down==was)return;
        if(down)[self.pressed addObject:token];else[self.pressed removeObject:token];
        NSInteger count=[self.held[key] integerValue]+(down?1:-1);self.held[key]=@(MAX(0,count));
        BOOL ctrl=[self.held[@((7<<16)|224)] intValue]||[self.held[@((7<<16)|228)] intValue];
        BOOL alt=[self.held[@((7<<16)|226)] intValue]||[self.held[@((7<<16)|230)] intValue];
        BOOL shift=[self.held[@((7<<16)|225)] intValue]||[self.held[@((7<<16)|229)] intValue];
        if(page==7&&down&&ctrl&&((alt&&usage==16)||(shift&&usage==41))) {dispatch_async(dispatch_get_main_queue(),^{[self stop:@""];});return;}
        if((down&&count==1)||(!down&&count==0))[self.frames addObject:[NSString stringWithFormat:@"k %u %u %d",page,usage,down?1:0]];
        self.keyEvents++;
    } else if(page==1&&IOHIDElementIsRelative(element)) {
        if(usage==0x30)self.dx+=v;else if(usage==0x31)self.dy+=v;else if(usage==0x38)self.sy+=v;
        self.mouseEvents++;
    } else if(page==9&&usage>=1&&usage<=5) {
        [self.frames addObject:[NSString stringWithFormat:@"b %u %d",usage,v?1:0]];self.mouseEvents++;
    } else if(page==12&&usage==0x238) {self.sx+=v;self.mouseEvents++;}
    if(self.frames.count>2048)[self stop:@"输入队列过长，已恢复本地控制。"];
}
- (void)tick {
    NSTimeInterval now=[NSDate timeIntervalSinceReferenceDate];
    if(now-self.lastPoll>.1) {
        self.lastPoll=now;NSDictionary *cmd=Read(@"selective-input-command.json");
        NSString *identifier=cmd[@"id"];
        if(identifier.length&&![identifier isEqualToString:self.lastCommand]) {
            self.lastCommand=identifier;
            if([cmd[@"target"] isEqualToString:@"windows"]) {if([self.mode isEqualToString:@"windows"])[self profile:@"windows"];else[self start];}
            else if([cmd[@"target"] isEqualToString:@"mac"]) {BOOL alreadyLocal=[self.mode isEqualToString:@"mac"];[self stop:@""];if(alreadyLocal)[self profile:@"mac"];}
        }
    }
    if([self.mode isEqualToString:@"connecting"]&&now-self.started>8)[self stop:@"Windows 接收端连接超时，外接键鼠保持在 Mac。"];
    if([self.mode isEqualToString:@"windows"] || ([self.mode isEqualToString:@"connecting"] && self.transportReady)) {
        if(self.dx||self.dy) {[self.frames addObject:[NSString stringWithFormat:@"m %lld %lld",MAX(-10000,MIN(10000,self.dx)),MAX(-10000,MIN(10000,self.dy))]];self.dx=self.dy=0;}
        if(self.sx||self.sy) {[self.frames addObject:[NSString stringWithFormat:@"s %lld %lld",MAX(-100,MIN(100,self.sx)),MAX(-100,MIN(100,self.sy))]];self.sx=self.sy=0;}
        if(now-self.lastHeartbeat>.4){[self.frames addObject:@"h"];self.lastHeartbeat=now;}
        if(self.frames.count) {
            if(self.pendingWrites>128){[self stop:@"网络积压，已恢复本地输入。"];return;}
            NSData *data=[[[self.frames componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];[self.frames removeAllObjects];
            NSFileHandle *handle=self.socketHandle;NSInteger generation=self.generation;self.pendingWrites++;
            dispatch_async(self.writer,^{BOOL failed=NO;@try{[handle writeData:data];}@catch(NSException *e){(void)e;failed=YES;}
                dispatch_async(dispatch_get_main_queue(),^{self.pendingWrites--;if(failed&&generation==self.generation)[self stop:@"网络写入失败，已恢复本地输入。"];});});
        }
    }
    if(now-self.lastStatus>.5) {
        self.lastStatus=now;
        [self publish];
    }
}
- (void)run {
    self.mode=@"mac";self.error=@"";self.devices=[NSMutableArray array];self.seized=[NSMutableSet set];self.pressed=[NSMutableSet set];self.held=[NSMutableDictionary dictionary];self.frames=[NSMutableArray array];self.writer=dispatch_queue_create("local.chilltong.input-writer",DISPATCH_QUEUE_SERIAL);
    RecoverSelectiveMappings();
    self.lastCommand=[NSUUID UUID].UUIDString;Write(@"selective-input-command.json",@{@"id":self.lastCommand,@"target":@"mac"});
    self.manager=IOHIDManagerCreate(NULL,kIOHIDOptionsTypeNone);
    NSArray *matching=@[@{@kIOHIDVendorIDKey:@1452,@kIOHIDProductIDKey:@591},@{@kIOHIDVendorIDKey:@14073,@kIOHIDProductIDKey:@43552}];
    IOHIDManagerSetDeviceMatchingMultiple(self.manager,(__bridge CFArrayRef)matching);
    IOHIDManagerScheduleWithRunLoop(self.manager,CFRunLoopGetCurrent(),kCFRunLoopDefaultMode);
    signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN);signal(SIGPIPE,SIG_IGN);
    self.termSignal=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
    self.intSignal=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGINT,0,dispatch_get_main_queue());
    dispatch_source_set_event_handler(self.termSignal,^{[self stop:@"转发后台已停止，外接输入已恢复本地。"];exit(0);});dispatch_resume(self.termSignal);
    dispatch_source_set_event_handler(self.intSignal,^{[self stop:@"转发后台已停止，外接输入已恢复本地。"];exit(0);});dispatch_resume(self.intSignal);
    [NSTimer scheduledTimerWithTimeInterval:.008 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self publish];Log(@"Device-selective router ready. No global event tap is installed.");
    [[NSRunLoop currentRunLoop] run];
}
@end

int RunSelectiveRouter(void) {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:Root() withIntermediateDirectories:YES attributes:nil error:nil];
        int lock=open(File(@"selective-input.lock").fileSystemRepresentation,O_CREAT|O_RDWR,0600);
        if(lock<0||flock(lock,LOCK_EX|LOCK_NB)!=0)return 2;
        Router *router=[Router new];[router run];close(lock);return 0;
    }
}
