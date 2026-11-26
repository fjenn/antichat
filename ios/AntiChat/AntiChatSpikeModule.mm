// AntiChat spike harness: process memory, thermal state, launch options and
// small file helpers for src/antichat/spike. Debug tooling only.

#import <React/RCTBridgeModule.h>
#import <UIKit/UIKit.h>
#import <os/proc.h>
#import <mach/mach.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>

static NSString *AntiChatThermalName(NSProcessInfoThermalState state) {
  switch (state) {
    case NSProcessInfoThermalStateNominal: return @"nominal";
    case NSProcessInfoThermalStateFair: return @"fair";
    case NSProcessInfoThermalStateSerious: return @"serious";
    case NSProcessInfoThermalStateCritical: return @"critical";
  }
  return @"unknown";
}

static void AntiChatReadMemory(uint64_t *footprint, uint64_t *resident, uint64_t *available) {
  task_vm_info_data_t vmInfo;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count);
  *footprint = (kr == KERN_SUCCESS) ? vmInfo.phys_footprint : 0;
  *resident = (kr == KERN_SUCCESS) ? vmInfo.resident_size : 0;
  *available = os_proc_available_memory();
}

static NSString *AntiChatSysctlString(const char *name) {
  size_t size = 0;
  if (sysctlbyname(name, NULL, &size, NULL, 0) != 0 || size == 0) return @"";
  NSMutableData *data = [NSMutableData dataWithLength:size];
  if (sysctlbyname(name, data.mutableBytes, &size, NULL, 0) != 0) return @"";
  return [NSString stringWithUTF8String:(const char *)data.bytes] ?: @"";
}

@interface AntiChatSpikeModule : NSObject <RCTBridgeModule>
@end

@implementation AntiChatSpikeModule {
  dispatch_source_t _timer;
  dispatch_queue_t _queue;
  uint64_t _peakFootprint;
  uint64_t _peakResident;
  uint64_t _minAvailable;
  NSInteger _maxThermal;
  NSUInteger _samples;
}

RCT_EXPORT_MODULE(AntiChatSpike)

+ (BOOL)requiresMainQueueSetup { return NO; }

- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("ai.antichat.spike.sampler", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (NSString *)documentsDir {
  return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

// Launch options come from `-antichatSpike 1`-style launch arguments (read
// through the NSUserDefaults argument domain) or ANTICHAT_SPIKE* environment
// variables. Returned synchronously so the JS root can pick the harness.
RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(getLaunchConfig) {
  NSProcessInfo *info = [NSProcessInfo processInfo];
  NSMutableDictionary *options = [NSMutableDictionary dictionary];
  NSDictionary *argDomain = [[NSUserDefaults standardUserDefaults] volatileDomainForName:NSArgumentDomain];
  [argDomain enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
    if ([key hasPrefix:@"antichatSpike"]) options[key] = [value description];
  }];
  [info.environment enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
    if (![key hasPrefix:@"ANTICHAT_SPIKE"]) return;
    // ANTICHAT_SPIKE_SUSTAIN_SEC -> antichatSpikeSustainSec
    NSArray<NSString *> *parts = [[key lowercaseString] componentsSeparatedByString:@"_"];
    NSMutableString *camel = [NSMutableString stringWithString:parts.firstObject];
    for (NSUInteger i = 1; i < parts.count; i++) [camel appendString:[parts[i] capitalizedString]];
    if (!options[camel]) options[camel] = value;
  }];
  BOOL enabled = [info.arguments containsObject:@"-antichatSpike"] || options[@"antichatSpike"] != nil;

  struct utsname systemInfo;
  uname(&systemInfo);
  NSString *machine = info.environment[@"SIMULATOR_MODEL_IDENTIFIER"] ?: [NSString stringWithUTF8String:systemInfo.machine];
#if TARGET_OS_SIMULATOR
  BOOL simulator = YES;
#else
  BOOL simulator = NO;
#endif
  return @{
    @"enabled": @(enabled),
    @"options": options,
    @"documentsDir": [self documentsDir] ?: @"",
    @"device": @{
      @"machine": machine ?: @"",
      @"simulator": @(simulator),
      @"os_version": [UIDevice currentDevice].systemVersion ?: @"",
      @"os_build": AntiChatSysctlString("kern.osversion"),
      @"physical_memory": @(info.physicalMemory),
      @"cores": @(info.activeProcessorCount),
      @"low_power_mode": @(info.lowPowerModeEnabled),
    },
  };
}

RCT_EXPORT_METHOD(getMemory:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  uint64_t footprint, resident, available;
  AntiChatReadMemory(&footprint, &resident, &available);
  NSProcessInfoThermalState thermal = [NSProcessInfo processInfo].thermalState;
  resolve(@{
    @"phys_footprint": @(footprint),
    @"resident_size": @(resident),
    @"available": @(available),
    @"thermal": AntiChatThermalName(thermal),
    @"thermal_level": @((NSInteger)thermal),
  });
}

// Samples memory on a native timer, so peaks are caught while JS is busy.
RCT_EXPORT_METHOD(startSampling:(double)intervalMs) {
  dispatch_async(_queue, ^{
    if (self->_timer) dispatch_source_cancel(self->_timer);
    self->_peakFootprint = 0;
    self->_peakResident = 0;
    self->_minAvailable = UINT64_MAX;
    self->_maxThermal = 0;
    self->_samples = 0;
    self->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
    uint64_t interval = (uint64_t)(MAX(intervalMs, 100.0) * NSEC_PER_MSEC);
    dispatch_source_set_timer(self->_timer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, interval / 10);
    dispatch_source_set_event_handler(self->_timer, ^{ [self sampleOnce]; });
    dispatch_resume(self->_timer);
  });
}

- (void)sampleOnce {
  uint64_t footprint, resident, available;
  AntiChatReadMemory(&footprint, &resident, &available);
  if (footprint > _peakFootprint) _peakFootprint = footprint;
  if (resident > _peakResident) _peakResident = resident;
  if (available > 0 && available < _minAvailable) _minAvailable = available;
  NSInteger thermal = (NSInteger)[NSProcessInfo processInfo].thermalState;
  if (thermal > _maxThermal) _maxThermal = thermal;
  _samples++;
}

- (NSDictionary *)samplingSummary {
  return @{
    @"peak_phys_footprint": @(_peakFootprint),
    @"peak_resident_size": @(_peakResident),
    @"min_available": @(_minAvailable == UINT64_MAX ? 0 : _minAvailable),
    @"max_thermal": AntiChatThermalName((NSProcessInfoThermalState)_maxThermal),
    @"samples": @(_samples),
  };
}

RCT_EXPORT_METHOD(readSampling:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(_queue, ^{
    [self sampleOnce];
    resolve([self samplingSummary]);
  });
}

RCT_EXPORT_METHOD(stopSampling:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(_queue, ^{
    [self sampleOnce];
    if (self->_timer) {
      dispatch_source_cancel(self->_timer);
      self->_timer = nil;
    }
    resolve([self samplingSummary]);
  });
}

// Lists *.gguf under Documents/<dir>, smallest first.
RCT_EXPORT_METHOD(listModels:(NSString *)dir
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *root = [[self documentsDir] stringByAppendingPathComponent:dir];
  [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
  NSMutableArray *models = [NSMutableArray array];
  for (NSString *name in [fm contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
    if (![[name.pathExtension lowercaseString] isEqualToString:@"gguf"]) continue;
    NSString *path = [root stringByAppendingPathComponent:name];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    [models addObject:@{@"name": name, @"path": path, @"size": attrs[NSFileSize] ?: @0}];
  }
  [models sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    return [a[@"size"] compare:b[@"size"]];
  }];
  resolve(models);
}

RCT_EXPORT_METHOD(writeFile:(NSString *)relativePath
                  content:(NSString *)content
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
  NSString *path = [[self documentsDir] stringByAppendingPathComponent:relativePath];
  NSError *error = nil;
  [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                            withIntermediateDirectories:YES attributes:nil error:nil];
  if ([content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
    resolve(path);
  } else {
    reject(@"antichat_write_failed", error.localizedDescription, error);
  }
}

RCT_EXPORT_METHOD(readFile:(NSString *)relativePath
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
  NSString *path = [[self documentsDir] stringByAppendingPathComponent:relativePath];
  NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
  resolve(content ?: [NSNull null]);
}

RCT_EXPORT_METHOD(appendLine:(NSString *)relativePath line:(NSString *)line) {
  NSString *path = [[self documentsDir] stringByAppendingPathComponent:relativePath];
  NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
  dispatch_async(_queue, ^{
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle closeFile];
  });
}

RCT_EXPORT_METHOD(setKeepAwake:(BOOL)enabled) {
  dispatch_async(dispatch_get_main_queue(), ^{
    [UIApplication sharedApplication].idleTimerDisabled = enabled;
  });
}

@end
