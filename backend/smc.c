/*
 * smc.c - SMC Interface with Persistent Wake Loop
 * Keeps SMC connection open and writes continuously until fan responds
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
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

kern_return_t SMCWriteFanFloat(const char *key, float value) {
    SMCVal_t val;
    if (SMCReadKey(key, &val) != kIOReturnSuccess) return kIOReturnError;
    if (strcmp(val.dataType, "flt ") == 0) memcpy(val.bytes, &value, sizeof(float));
    else if (strcmp(val.dataType, "fpe2") == 0) {
        unsigned short enc = (unsigned short)(value * 4.0f);
        val.bytes[0] = (enc >> 8) & 0xFF; val.bytes[1] = enc & 0xFF;
    }
    return SMCWriteKey(&val);
}

// Set fan to manual mode
void SMCSetFanManual(int fan) {
    char key[5];
    SMCVal_t val;
    snprintf(key, 5, "F%dMd", fan);
    if (SMCReadKey(key, &val) == kIOReturnSuccess && val.dataSize > 0) {
        val.bytes[0] = 1;
        SMCWriteKey(&val);
    }
}

// PERSISTENT WAKE LOOP - keeps writing until fan responds
void SMCWakeFan(int fan, float targetRpm, int maxSeconds) {
    char keyTg[5], keyMn[5];
    snprintf(keyTg, 5, "F%dTg", fan);
    snprintf(keyMn, 5, "F%dMn", fan);
    
    int maxIterations = maxSeconds * 10; // 100ms per iteration
    
    printf("Waking fan %d to %.0f RPM (max %d seconds)...\n", fan, targetRpm, maxSeconds);
    fflush(stdout);
    
    for (int i = 0; i < maxIterations; i++) {
        // Set manual mode
        SMCSetFanManual(fan);
        
        // Set minimum speed
        SMCWriteFanFloat(keyMn, targetRpm);
        
        // Set target speed
        SMCWriteFanFloat(keyTg, targetRpm);
        
        // Check if fan responded
        usleep(100000); // 100ms
        float currentRpm = SMCGetFanRPM(fan);
        
        if (currentRpm > 100) {
            printf("Fan %d woke up! RPM: %.0f (after %d ms)\n", fan, currentRpm, (i + 1) * 100);
            return;
        }
        
        // Progress indicator every second
        if ((i + 1) % 10 == 0) {
            printf("  Still trying... (%d/%d sec)\n", (i + 1) / 10, maxSeconds);
            fflush(stdout);
        }
    }
    
    float finalRpm = SMCGetFanRPM(fan);
    printf("Timeout. Fan %d RPM: %.0f\n", fan, finalRpm);
}

// Simple set (no wait loop)
void SMCSetFanRPM(int fan, float rpm) {
    char key[5];
    SMCSetFanManual(fan);
    snprintf(key, 5, "F%dMn", fan);
    SMCWriteFanFloat(key, rpm);
    snprintf(key, 5, "F%dTg", fan);
    SMCWriteFanFloat(key, rpm);
}

void SMCSetFanAuto(int fan) {
    char key[5];
    SMCVal_t val;
    snprintf(key, 5, "F%dMd", fan);
    if (SMCReadKey(key, &val) == kIOReturnSuccess && val.dataSize > 0) {
        val.bytes[0] = 0;
        SMCWriteKey(&val);
    }
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
    
    char as_cpu_sfx[] = "159DHLPTXbfjnrUV";
    int cpu_num = 1;
    for (int i = 0; as_cpu_sfx[i]; i++) {
        char key[5]; snprintf(key, 5, "Tp0%c", as_cpu_sfx[i]);
        double temp = SMCGetTemperature(key);
        if (temp > 5.0 && temp < 130.0) {
            printf("TEMP:%s:CPU Core %d:%.1f\n", key, cpu_num++, temp);
            if (temp > maxCpu) maxCpu = temp; sumCpu += temp; countCpu++;
        }
    }
    
    char as_gpu_sfx[] = "5DLTXbfjnr19HPV";
    int gpu_num = 1;
    for (int i = 0; as_gpu_sfx[i]; i++) {
        char key[5]; snprintf(key, 5, "Tg0%c", as_gpu_sfx[i]);
        double temp = SMCGetTemperature(key);
        if (temp > 5.0 && temp < 130.0) printf("TEMP:%s:GPU Core %d:%.1f\n", key, gpu_num++, temp);
    }
    
    for (int i = 0; i <= 15; i++) {
        char key[5]; snprintf(key, 5, "TC%dC", i);
        double temp = SMCGetTemperature(key);
        if (temp > 5.0 && temp < 130.0) {
            printf("TEMP:%s:CPU Core %d:%.1f\n", key, i, temp);
            if (temp > maxCpu) maxCpu = temp; sumCpu += temp; countCpu++;
        }
    }
    
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
    if (countCpu > 0) {
        printf("TEMP:_AVG:Average CPU:%.1f\n", sumCpu / countCpu);
        printf("TEMP:_MAX:Hottest CPU:%.1f\n", maxCpu);
    }
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        printf("Usage:\n");
        printf("  smc_util -l                    List fans\n");
        printf("  smc_util -s                    List sensors\n");
        printf("  smc_util -f <n> <rpm>          Set fan n to rpm (-1 for auto)\n");
        printf("  smc_util -w <n> <rpm> [secs]   Wake fan with persistent loop\n");
        return 1;
    }
    
    if (SMCOpen() != kIOReturnSuccess) { fprintf(stderr, "Failed to open SMC\n"); return 1; }
    
    if (strcmp(argv[1], "-l") == 0) {
        listFans();
    } else if (strcmp(argv[1], "-s") == 0) {
        listSensors();
    } else if (strcmp(argv[1], "-f") == 0 && argc >= 4) {
        int fan = atoi(argv[2]);
        float rpm = atof(argv[3]);
        if (rpm < 0) {
            SMCSetFanAuto(fan);
            printf("OK:auto\n");
        } else {
            SMCSetFanRPM(fan, rpm);
            printf("OK:%.0f\n", rpm);
        }
    } else if (strcmp(argv[1], "-w") == 0 && argc >= 4) {
        int fan = atoi(argv[2]);
        float rpm = atof(argv[3]);
        int secs = (argc >= 5) ? atoi(argv[4]) : 30; // Default 30 seconds
        SMCWakeFan(fan, rpm, secs);
    } else {
        printf("Unknown command\n");
    }
    
    SMCClose();
    return 0;
}
