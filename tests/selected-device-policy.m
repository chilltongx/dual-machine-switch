#include "../selective-input/Router.m"
#include <assert.h>
int main(void) {
    @autoreleasepool {
        assert(Selected(@"Flow84-L@Lofree ",@"Bluetooth Low Energy",@1452,@591,@NO));
        assert(Selected(@"X7 Receiver 8K",@"USB",@14073,@43552,@NO));
        assert(!Selected(@"Apple Internal Keyboard / Trackpad",@"FIFO",@1452,@591,@YES));
        assert(!Selected(@"Flow84-L@Lofree ",@"Bluetooth Low Energy",@1452,@591,@YES));
        assert(!Selected(@"Other Keyboard",@"Bluetooth Low Energy",@1452,@591,@NO));
        assert(!Selected(@"X7 Receiver 8K",@"FIFO",@14073,@43552,@NO));
        assert(!Selected(@"X7 Receiver 8K",@"USB",@1452,@591,@NO));
        puts("Built-in and unrelated devices excluded; only the two selected external devices allowed.");
    }
    return 0;
}
