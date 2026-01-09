/*
 * smc.c - Universal SMC Interface
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <IOKit/IOKitLib.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES  5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } SMCKeyData_keyInfo_t;
typedef char SMCBytes_t[32];
typedef struct { UInt32 key; char padding1[24]; SMCKeyData_keyInfo_t keyInfo; char result; char status; char data8; UInt32 data32; SMCBytes_t bytes; } SMCKeyData_t;
typedef char UInt32Char_t[5];
typedef struct { UInt32Char_t key; UInt32 dataSize; UInt32Char_t dataType; SMCBytes_t bytes; } SMCVal_t;

static io_connect_t conn;

UInt32 _strtoul(char *str, int size, int base) {
    UInt32 total = 0;
    for (int i = 0; i < size; i++) total += ((unsigned char)(str[i]) << (size - 1 - i) * 8);
    return total;
}

void _ultostr(char *str, UInt32 val) {
    str[0] = (val >> 24) & 0xFF; str[1] = (val >> 16) & 0xFF; str[2] = (val >> 8) & 0xFF; str[3] = val & 0xFF; str[4] = '\0';
}

kern_return_t SMCOpen(void) {
    io_iterator_t iterator; io_object_t device;
    CFMutableDictionaryRef matchingDictionary = IOServiceMatching("AppleSMC");
    kern_return_t result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator);
    if (result != kIOReturnSuccess) return result;
    device = IOIteratorNext(iterator); IOObjectRelease(iterator);
    if (device == 0) return kIOReturnNotFound;
    result = IOServiceOpen(device, mach_task_self(), 0, &conn);
    IOObjectRelease(device); return result;
}

kern_return_t SMCClose(void) { return IOServiceClose(conn); }

kern_return_t SMCCall(int index, SMCKeyData_t *inputStructure, SMCKeyData_t *outputStructure) {
    size_t structureInputSize = sizeof(SMCKeyData_t), structureOutputSize = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(conn, index, inputStructure, structureInputSize, outputStructure, &structureOutputSize);
}

kern_return_t SMCReadKey(const char *key, SMCVal_t *val) {
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out)); memset(val, 0, sizeof(SMCVal_t));
    in.key = _strtoul((char*)key, 4, 16); in.data8 = SMC_CMD_READ_KEYINFO;
    if (SMCCall(KERNEL_INDEX_SMC, &in, &out) != kIOReturnSuccess) return kIOReturnError;
    val->dataSize = out.keyInfo.dataSize; _ultostr(val->dataType, out.keyInfo.dataType);
    in.keyInfo.dataSize = val->dataSize; in.data8 = SMC_CMD_READ_BYTES;
    if (SMCCall(KERNEL_INDEX_SMC, &in, &out) != kIOReturnSuccess) return kIOReturnError;
    memcpy(val->bytes, out.bytes, sizeof(out.bytes)); strncpy(val->key, key, 4); val->key[4] = '\0';
    return kIOReturnSuccess;
}

kern_return_t SMCWriteKey(SMCVal_t *val) {
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
    in.key = _strtoul(val->key, 4, 16); in.data8 = SMC_CMD_READ_KEYINFO;
    if (SMCCall(KERNEL_INDEX_SMC, &in, &out) != kIOReturnSuccess) return kIOReturnError;
    in.keyInfo.dataSize = val->dataSize; in.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(in.bytes, val->bytes, sizeof(val->bytes));
    return SMCCall(KERNEL_INDEX_SMC, &in, &out);
}

double SMCGetTemperature(const char *key) {
    SMCVal_t val;
    if (SMCReadKey(key, &val) != kIOReturnSuccess || val.dataSize == 0) return 0.0;
    if (strcmp(val.dataType, "sp78") == 0) return ((val.bytes[0] * 256 + (unsigned char)val.bytes[1])) / 256.0;
    if (strcmp(val.dataType, "flt ") == 0) { float f; memcpy(&f, val.bytes, sizeof(float)); return (double)f; }
    return 0.0;
}

float SMCGetFanFloat(const char *key) {
    SMCVal_t val;
    if (SMCReadKey(key, &val) != kIOReturnSuccess) return -1.0f;
    if (strcmp(val.dataType, "fpe2") == 0) return ((val.bytes[0] << 8) | (unsigned char)val.bytes[1]) / 4.0f;
    if (strcmp(val.dataType, "flt ") == 0) { float f; memcpy(&f, val.bytes, sizeof(float)); return f; }
    return -1.0f;
}

int SMCGetFanCount(void) { SMCVal_t val; if (SMCReadKey("FNum", &val) != kIOReturnSuccess) return 0; return (int)val.bytes[0]; }
float SMCGetFanRPM(int n) { char k[5]; snprintf(k, 5, "F%dAc", n); return SMCGetFanFloat(k); }
float SMCGetFanMin(int n) { char k[5]; snprintf(k, 5, "F%dMn", n); return SMCGetFanFloat(k); }
float SMCGetFanMax(int n) { char k[5]; snprintf(k, 5, "F%dMx", n); return SMCGetFanFloat(k); }

kern_return_t SMCSetFanRPM(int fan, float rpm) {
    SMCVal_t val; char key[5];
    snprintf(key, 5, "F%dMd", fan);
    if (SMCReadKey(key, &val) == kIOReturnSuccess && val.dataSize > 0) { val.bytes[0] = 1; SMCWriteKey(&val); }
    snprintf(key, 5, "F%dTg", fan);
    if (SMCReadKey(key, &val) != kIOReturnSuccess) return kIOReturnError;
    if (strcmp(val.dataType, "flt ") == 0) memcpy(val.bytes, &rpm, sizeof(float));
    else { unsigned short enc = (unsigned short)(rpm * 4.0f); val.bytes[0] = (enc >> 8) & 0xFF; val.bytes[1] = enc & 0xFF; }
    return SMCWriteKey(&val);
}

kern_return_t SMCSetFanAuto(int fan) {
    SMCVal_t val; char key[5];
    snprintf(key, 5, "F%dMd", fan);
    if (SMCReadKey(key, &val) == kIOReturnSuccess && val.dataSize > 0) { val.bytes[0] = 0; return SMCWriteKey(&val); }
    return kIOReturnSuccess;
}

void listFans(void) {
    int numFans = SMCGetFanCount();
    printf("FANS:%d\n", numFans);
    for (int i = 0; i < numFans; i++) printf("FAN:%d:%.0f:%.0f:%.0f\n", i, SMCGetFanRPM(i), SMCGetFanMin(i), SMCGetFanMax(i));
}

void listSensors(void) {
    double maxCpu = 0, sumCpu = 0;
    int countCpu = 0;
    
    printf("SENSORS\n");
    
    // Apple Silicon CPU cores - Tp0* pattern
    char as_cpu_sfx[] = "159DHLPTXbfjnrUV";
    int cpu_num = 1;
    for (int i = 0; as_cpu_sfx[i]; i++) {
        char key[5];
        snprintf(key, 5, "Tp0%c", as_cpu_sfx[i]);
        double temp = SMCGetTemperature(key);
        if (temp > 5.0 && temp < 130.0) {
            printf("TEMP:%s:CPU Core %d:%.1f\n", key, cpu_num++, temp);
            if (temp > maxCpu) maxCpu = temp;
            sumCpu += temp; countCpu++;
        }
    }
    
    // Apple Silicon GPU cores - Tg0* pattern
    char as_gpu_sfx[] = "5DLTXbfjnr19HPV";
    int gpu_num = 1;
    for (int i = 0; as_gpu_sfx[i]; i++) {
        char key[5];
        snprintf(key, 5, "Tg0%c", as_gpu_sfx[i]);
        double temp = SMCGetTemperature(key);
        if (temp > 5.0 && temp < 130.0) {
            printf("TEMP:%s:GPU Core %d:%.1f\n", key, gpu_num++, temp);
        }
    }
    
    // Intel CPU cores - TC*C pattern
    for (int i = 0; i <= 15; i++) {
        char key[5];
        snprintf(key, 5, "TC%dC", i);
        double temp = SMCGetTemperature(key);
        if (temp > 5.0 && temp < 130.0) {
            printf("TEMP:%s:CPU Core %d:%.1f\n", key, i, temp);
            if (temp > maxCpu) maxCpu = temp;
            sumCpu += temp; countCpu++;
        }
    }
    
    // System sensors
    struct { const char *key; const char *name; } sys[] = {
        {"TC0P", "CPU Proximity"}, {"TC0D", "CPU Die"}, {"TG0D", "GPU Die"},
        {"TW0P", "Wireless"}, {"Ts0P", "Palm Rest"}, {"Ts1P", "Palm Rest Left"},
        {"TB0T", "Battery"}, {"TB1T", "Battery 1"}, {"TB2T", "Battery 2"},
        {"Tp0C", "Power Supply"}, {"TH0a", "SSD A"}, {"TH0b", "SSD B"},
        {"Tm0P", "Memory"}, {"TA0P", "Ambient"}, {NULL, NULL}
    };
    for (int i = 0; sys[i].key; i++) {
        double temp = SMCGetTemperature(sys[i].key);
        if (temp > 5.0 && temp < 130.0) printf("TEMP:%s:%s:%.1f\n", sys[i].key, sys[i].name, temp);
    }
    
    // Virtual aggregates
    if (countCpu > 0) {
        printf("TEMP:_AVG:Average CPU:%.1f\n", sumCpu / countCpu);
        printf("TEMP:_MAX:Hottest CPU:%.1f\n", maxCpu);
    }
}

int main(int argc, char *argv[]) {
    if (argc < 2) { printf("Usage: smc_util -l|-s|-f <n> <rpm>\n"); return 1; }
    if (SMCOpen() != kIOReturnSuccess) return 1;
    if (strcmp(argv[1], "-l") == 0) listFans();
    else if (strcmp(argv[1], "-s") == 0) listSensors();
    else if (strcmp(argv[1], "-f") == 0 && argc >= 4) {
        int fan = atoi(argv[2]); float rpm = atof(argv[3]);
        if (rpm < 0) SMCSetFanAuto(fan); else SMCSetFanRPM(fan, rpm);
        printf("OK\n");
    }
    SMCClose(); return 0;
}
