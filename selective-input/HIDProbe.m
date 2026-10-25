#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
int main(int argc,const char **argv) {
    @autoreleasepool {
        IOHIDManagerRef manager=IOHIDManagerCreate(NULL,kIOHIDOptionsTypeNone);
        NSArray *matches=@[@{@kIOHIDVendorIDKey:@1452,@kIOHIDProductIDKey:@591},@{@kIOHIDVendorIDKey:@14073,@kIOHIDProductIDKey:@43552}];
        IOHIDManagerSetDeviceMatchingMultiple(manager,(__bridge CFArrayRef)matches);
        IOReturn opened=IOHIDManagerOpen(manager,kIOHIDOptionsTypeNone);
        printf("manager=0x%x\n",opened);
        NSSet *devices=CFBridgingRelease(IOHIDManagerCopyDevices(manager));
        IOHIDManagerClose(manager,kIOHIDOptionsTypeNone);
        for(id object in devices) {
            IOHIDDeviceRef device=(__bridge IOHIDDeviceRef)object;
            NSString *product=(__bridge NSString*)IOHIDDeviceGetProperty(device,CFSTR(kIOHIDProductKey));
            NSString *transport=(__bridge NSString*)IOHIDDeviceGetProperty(device,CFSTR(kIOHIDTransportKey));
            NSNumber *page=(__bridge NSNumber*)IOHIDDeviceGetProperty(device,CFSTR(kIOHIDPrimaryUsagePageKey));
            NSNumber *usage=(__bridge NSNumber*)IOHIDDeviceGetProperty(device,CFSTR(kIOHIDPrimaryUsageKey));
            BOOL allowed=([product hasPrefix:@"Flow84-L@Lofree"] && [transport containsString:@"Bluetooth"]) || ([product isEqualToString:@"X7 Receiver 8K"] && [transport isEqualToString:@"USB"]);
            if(!allowed || !([page intValue]==1 || [page intValue]==12)) continue;
            printf("%s transport=%s page=%d usage=%d",product.UTF8String,transport.UTF8String,[page intValue],[usage intValue]);
            if(argc==2 && strcmp(argv[1],"--seize-check")==0) {
                IOReturn result=IOHIDDeviceOpen(device,kIOHIDOptionsTypeSeizeDevice);
                printf(" seize=0x%x",result);
                if(result==kIOReturnSuccess) IOHIDDeviceClose(device,kIOHIDOptionsTypeSeizeDevice);
            }
            printf("\n");
        }
        CFRelease(manager);
    }
    return 0;
}
