@import Foundation;
#include <assert.h>
#include "i2c.h"

static uint32_t lastLength;
static UInt8 lastPacket[16];
IOReturn IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t chip, uint32_t address, void *buffer, uint32_t length) {
    (void)service; (void)chip; (void)address;
    lastLength = length;
    memcpy(lastPacket, buffer, length);
    return 0;
}
IOReturn IOAVServiceReadI2C(IOAVServiceRef service, uint32_t chip, uint32_t offset, void *buffer, uint32_t length) {
    (void)service; (void)chip; (void)offset; (void)buffer; (void)length;
    return 0;
}
int main(void) {
    DDCPacket request = createDDCPacket(0x10);
    prepareDDCRead(&request);
    const UInt8 expected[] = {0x82, 0x01, 0x10, 0xac};
    assert(memcmp(request.data, expected, 4) == 0);
    prepareDDCRead(&request);
    assert(memcmp(request.data, expected, 4) == 0);
    performDDCWrite(NULL, &request);
    assert(lastLength == 4);

    // Input value 0xd8 produces a zero checksum: it must still be transmitted.
    DDCPacket write = createDDCPacket(0x60);
    prepareDDCWrite(&write, 0xd8);
    assert(write.data[5] == 0);
    performDDCWrite(NULL, &write);
    assert(lastLength == 6 && lastPacket[5] == 0);

    // Published DDC reply: brightness 67, maximum 100 (12th byte is padding).
    char reply[] = {0x6e, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x43, 0x83, 0xf1};
    DDCValue result = convertI2CtoDDC(reply);
    assert(result.curValue == 67 && result.maxValue == 100);
    reply[9] ^= 1;
    assert(convertI2CtoDDC(reply).curValue == -1);
    memset(reply, 0, sizeof(reply));
    assert(convertI2CtoDDC(reply).curValue == -1);
    puts("DDC packet checks passed");
    return 0;
}
