/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBSimulatorBootStrategy.h"

#import <Cocoa/Cocoa.h>

#import <CoreSimulator/SimDevice.h>
#import <CoreSimulator/SimDevice+Removed.h>
#import <CoreSimulator/SimDeviceSet.h>
#import <CoreSimulator/SimDeviceType.h>

#import <SimulatorBridge/SimulatorBridge-Protocol.h>
#import <SimulatorBridge/SimulatorBridge.h>

#import <FBControlCore/FBControlCore.h>

#import "FBFramebuffer.h"
#import "FBFramebufferConfiguration.h"
#import "FBFramebufferConnectStrategy.h"
#import "FBSimulator+Helpers.h"
#import "FBSimulator+Private.h"
#import "FBSimulator.h"
#import "FBSimulatorBridge.h"
#import "FBSimulatorConnection.h"
#import "FBSimulatorError.h"
#import "FBSimulatorEventSink.h"
#import "FBSimulatorHID.h"
#import "FBSimulatorSet.h"
#import "FBSimulatorBootConfiguration+Helpers.h"
#import "FBSimulatorBootConfiguration.h"
#import "FBSimulatorLaunchCtl.h"
#import "FBSimulatorProcessFetcher.h"

/**
 Provides relevant options to CoreSimulator for Booting.
 */
@protocol FBCoreSimulatorBootOptions <NSObject>

/**
 YES if the Framebuffer should be created, NO otherwise.
 */
- (BOOL)shouldCreateFramebuffer;

/**
 The Options to provide to the CoreSimulator API.
 */
- (NSDictionary<NSString *, id> *)bootOptions;

@end

/**
 Provides an implementation of Launching a Simulator Application.
 */
@protocol FBSimulatorApplicationProcessLauncher <NSObject>

/**
 Launches the SimulatorApp Process.

 @param arguments the SimulatorApp process arguments.
 @param environment the environment for the process.
 @param error an error out for any error that occurs.
 @return YES if successful, NO otherwise.
 */
- (BOOL)launchSimulatorProcessWithArguments:(NSArray<NSString *> *)arguments environment:(NSDictionary<NSString *, NSString *> *)environment error:(NSError **)error;

@end

/**
 Provides Launch Options to a Simulator.
 */
@protocol FBSimulatorApplicationLaunchOptions <NSObject>

/**
 Creates and returns the arguments to pass to Xcode's Simulator.app for the reciever's configuration.

 @param configuration the configuration to base off.
 @param simulator the Simulator construct boot args for.
 @param error an error out for any error that occurs.
 @return an NSArray<NSString> of boot arguments, or nil if an error occurred.
 */
- (NSArray<NSString *> *)xcodeSimulatorApplicationArguments:(FBSimulatorBootConfiguration *)configuration simulator:(FBSimulator *)simulator error:(NSError **)error;

@end

@interface FBSimulatorApplicationLaunchStrategy : NSObject

@property (nonatomic, strong, readonly) FBSimulatorBootConfiguration *configuration;
@property (nonatomic, strong, readonly) FBSimulator *simulator;
@property (nonatomic, strong, readonly) id<FBSimulatorApplicationProcessLauncher> launcher;
@property (nonatomic, strong, readonly) id<FBSimulatorApplicationLaunchOptions> options;

@end

@interface FBCoreSimulatorBootStrategy : NSObject

@property (nonatomic, strong, readonly) FBSimulatorBootConfiguration *configuration;
@property (nonatomic, strong, readonly) FBSimulator *simulator;
@property (nonatomic, strong, readonly) id<FBCoreSimulatorBootOptions> options;

@end

@interface FBSimulatorBootStrategy ()

@property (nonatomic, strong, readonly) FBSimulatorBootConfiguration *configuration;
@property (nonatomic, strong, readonly) FBSimulator *simulator;
@property (nonatomic, strong, readonly) FBSimulatorApplicationLaunchStrategy *applicationStrategy;
@property (nonatomic, strong, readonly) FBCoreSimulatorBootStrategy *coreSimulatorStrategy;

- (instancetype)initWithConfiguration:(FBSimulatorBootConfiguration *)configuration simulator:(FBSimulator *)simulator applicationStrategy:(FBSimulatorApplicationLaunchStrategy *)applicationStrategy coreSimulatorStrategy:(FBCoreSimulatorBootStrategy *)coreSimulatorStrategy;

@end

@interface FBCoreSimulatorBootOptions_Xcode7 : NSObject <FBCoreSimulatorBootOptions>
@end

@interface FBCoreSimulatorBootOptions_Xcode8 : NSObject <FBCoreSimulatorBootOptions>

@property (nonatomic, strong, readonly) FBSimulatorBootConfiguration *configuration;

@end

@interface FBCoreSimulatorBootOptions_Xcode9 : NSObject <FBCoreSimulatorBootOptions>

@property (nonatomic, strong, readonly) FBSimulatorBootConfiguration *configuration;

@end

@implementation FBCoreSimulatorBootOptions_Xcode7

- (BOOL)shouldCreateFramebuffer
{
  // A Framebuffer is required in Xcode 7 currently, otherwise any interface that uses the Mach Interface for 'Host Support' will fail/hang.
  return YES;
}

- (NSDictionary<NSString *, id> *)bootOptions
{
  // The 'register-head-services' option will attach the existing 'frameBufferService' when the Simulator is booted.
  // Simulator.app behaves similarly, except we can't peek at the Framebuffer as it is in a protected process since Xcode 7.
  // Prior to Xcode 6 it was possible to shim into the Simulator process but codesigning now prevents this https://gist.github.com/lawrencelomax/27bdc4e8a433a601008f

  return @{
    @"register-head-services" : @YES,
  };
}

@end

@implementation FBCoreSimulatorBootOptions_Xcode8

- (instancetype)initWithConfiguration:(FBSimulatorBootConfiguration *)configuration
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _configuration = configuration;

  return self;
}

- (BOOL)shouldCreateFramebuffer
{
  // Framebuffer connection is optional on Xcode 8 so we should use the appropriate configuration.
  return self.configuration.shouldConnectFramebuffer;
}

- (NSDictionary<NSString *, id> *)bootOptions
{
  // Since Xcode 8 Beta 5, 'simctl' uses the 'SIMULATOR_IS_HEADLESS' argument.
  return @{
    @"register-head-services" : @YES,
    @"env" : @{
      @"SIMULATOR_IS_HEADLESS" : @1,
    },
  };
}

@end

@implementation FBCoreSimulatorBootOptions_Xcode9

- (instancetype)initWithConfiguration:(FBSimulatorBootConfiguration *)configuration
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _configuration = configuration;

  return self;
}

- (BOOL)shouldCreateFramebuffer
{
  // Framebuffer connection is optional on Xcode 9 so we should use the appropriate configuration.
  return self.configuration.shouldConnectFramebuffer;
}

- (NSDictionary<NSString *, id> *)bootOptions
{
  // We currently don't have semantics for headless launches that *don't* use the death-trigger behaviour.
  // Therefore we should keep consistency across Xcode versions and eventually add these semantics.
  return @{
    @"persist": @NO,
  };
}

@end

@implementation FBCoreSimulatorBootStrategy

- (instancetype)initWithConfiguration:(FBSimulatorBootConfiguration *)configuration simulator:(FBSimulator *)simulator options:(id<FBCoreSimulatorBootOptions>)options
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _configuration = configuration;
  _simulator = simulator;
  _options = options;

  return self;
}

- (FBSimulatorConnection *)performBootWithError:(NSError **)error
{
  // Only Boot with CoreSimulator when told to do so. Return early if not.
  if (!self.shouldBootWithCoreSimulator) {
    return [[FBSimulatorConnection alloc] initWithSimulator:self.simulator framebuffer:nil hid:nil];
  }

  // Create the Framebuffer (if required to do so).
  NSError *innerError = nil;
  FBFramebuffer *framebuffer = nil;
  if (self.options.shouldCreateFramebuffer) {
    FBFramebufferConfiguration *configuration = [self.configuration.framebuffer inSimulator:self.simulator];
    if (!configuration) {
      configuration = FBFramebufferConfiguration.defaultConfiguration;
      [self.simulator.logger logFormat:@"No Framebuffer Launch Configuration provided, but required. Using default of %@", configuration];
    }

    framebuffer = [[FBFramebufferConnectStrategy
      strategyWithConfiguration:configuration]
      connect:self.simulator error:&innerError];
    if (!framebuffer) {
      return [FBSimulatorError failWithError:innerError errorOut:error];
    }
  }

  // Create the HID Port
  FBSimulatorHID *hid = [FBSimulatorHID hidPortForSimulator:self.simulator error:&innerError];
  if (!hid) {
    return [FBSimulatorError failWithError:innerError errorOut:error];
  }

  // Booting is simpler than the Simulator.app launch process since the caller calls CoreSimulator Framework directly.
  // Just pass in the options to ensure that the framebuffer service is registered when the Simulator is booted.
  NSDictionary<NSString *, id> *options = self.options.bootOptions;
  if (![self.simulator.device bootWithOptions:options error:&innerError]) {
    return [[[[FBSimulatorError
      describeFormat:@"Failed to boot Simulator with options %@", options]
      inSimulator:self.simulator]
      causedBy:innerError]
      fail:error];
  }

  return [[FBSimulatorConnection alloc] initWithSimulator:self.simulator framebuffer:framebuffer hid:hid];
}

- (BOOL)shouldBootWithCoreSimulator
{
  return self.configuration.shouldUseDirectLaunch;
}

@end

@interface FBSimulatorApplicationProcessLauncher_Task : NSObject <FBSimulatorApplicationProcessLauncher>
@end

@interface FBSimulatorApplicationProcessLauncher_Workspace : NSObject <FBSimulatorApplicationProcessLauncher>
@end

@implementation FBSimulatorApplicationProcessLauncher_Task

- (BOOL)launchSimulatorProcessWithArguments:(NSArray<NSString *> *)arguments environment:(NSDictionary<NSString *, NSString *> *)environment error:(NSError **)error
{
  // Construct and start the task.
  FBTask *task = [[[[[FBTaskBuilder
    withLaunchPath:FBApplicationDescriptor.xcodeSimulator.binary.path]
    withArguments:arguments]
    withEnvironmentAdditions:environment]
    build]
    startAsynchronously];


  // Expect no immediate error.
  if (task.error) {
    return [[[FBSimulatorError
      describe:@"Failed to Launch Simulator Process"]
      causedBy:task.error]
      failBool:error];
  }
  return YES;
}

@end

@implementation FBSimulatorApplicationProcessLauncher_Workspace

- (BOOL)launchSimulatorProcessWithArguments:(NSArray<NSString *> *)arguments environment:(NSDictionary<NSString *, NSString *> *)environment error:(NSError **)error
{
  // The NSWorkspace API allows for arguments & environment to be provided to the launched application
  // Additionally, multiple Apps of the same application can be launched with the NSWorkspaceLaunchNewInstance option.
  NSURL *applicationURL = [NSURL fileURLWithPath:FBApplicationDescriptor.xcodeSimulator.path];
  NSDictionary *appLaunchConfiguration = @{
    NSWorkspaceLaunchConfigurationArguments : arguments,
    NSWorkspaceLaunchConfigurationEnvironment : environment,
  };

  NSError *innerError = nil;
  NSRunningApplication *application = [NSWorkspace.sharedWorkspace
    launchApplicationAtURL:applicationURL
    options:NSWorkspaceLaunchDefault | NSWorkspaceLaunchNewInstance | NSWorkspaceLaunchWithoutActivation
    configuration:appLaunchConfiguration
    error:&innerError];

  if (!application) {
    return [[[FBSimulatorError
      describeFormat:@"Failed to launch simulator application %@ with configuration %@", applicationURL, appLaunchConfiguration]
      causedBy:innerError]
      failBool:error];
  }
  return YES;
}

@end

@interface FBSimulatorApplicationLaunchOptions_Xcode7 : NSObject <FBSimulatorApplicationLaunchOptions>
@end

@implementation FBSimulatorApplicationLaunchOptions_Xcode7

- (NSArray<NSString *> *)xcodeSimulatorApplicationArguments:(FBSimulatorBootConfiguration *)configuration simulator:(FBSimulator *)simulator error:(NSError **)error
{
  // These arguments are based on the NSUserDefaults that are serialized for the Simulator.app.
  // These can be seen with `defaults read com.apple.iphonesimulator` and has default location of ~/Library/Preferences/com.apple.iphonesimulator.plist
  // NSUserDefaults for any application can be overriden in the NSArgumentDomain:
  // https://developer.apple.com/library/ios/documentation/Cocoa/Conceptual/UserDefaults/AboutPreferenceDomains/AboutPreferenceDomains.html#//apple_ref/doc/uid/10000059i-CH2-96930
  NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithArray:@[
    @"--args",
    @"-CurrentDeviceUDID", simulator.udid,
    @"-ConnectHardwareKeyboard", @"0",
  ]];
  FBScale scale = configuration.scale;
  if (scale) {
    [arguments addObjectsFromArray:@[
      [self lastScaleCommandLineSwitchForSimulator:simulator], scale,
    ]];
  }

  NSString *setPath = simulator.set.deviceSet.setPath;
  if (setPath) {
    if (!FBControlCoreGlobalConfiguration.supportsCustomDeviceSets) {
      return [[[FBSimulatorError describe:@"Cannot use custom Device Set on current platform"] inSimulator:simulator] fail:error];
    }
    [arguments addObjectsFromArray:@[@"-DeviceSetPath", setPath]];
  }
  return [arguments copy];
}

- (NSString *)lastScaleCommandLineSwitchForSimulator:(FBSimulator *)simulator
{
  return [NSString stringWithFormat:@"-SimulatorWindowLastScale-%@", simulator.device.deviceTypeIdentifier];
}

@end

@implementation FBSimulatorApplicationLaunchStrategy

- (instancetype)initWithConfiguration:(FBSimulatorBootConfiguration *)configuration simulator:(FBSimulator *)simulator launcher:(id<FBSimulatorApplicationProcessLauncher>)launcher options:(id<FBSimulatorApplicationLaunchOptions>)options
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _configuration = configuration;
  _simulator = simulator;
  _launcher = launcher;
  _options = options;

  return self;
}

- (BOOL)launchSimulatorApplicationWithError:(NSError **)error
{
  // Return early if we shouldn't launch the Application
  if (!self.shouldLaunchSimulatorApplication) {
    return YES;
  }

  // Fetch the Boot Arguments & Environment
  NSError *innerError = nil;
  NSArray *arguments = [self.options xcodeSimulatorApplicationArguments:self.configuration simulator:self.simulator error:&innerError];
  if (!arguments) {
    return [[[FBSimulatorError
      describeFormat:@"Failed to create boot args for Configuration %@", self.configuration]
      causedBy:innerError]
      failBool:error];
  }
  // Add the UDID marker to the subprocess environment, so that it can be queried in any process.
  NSDictionary *environment = @{
    FBSimulatorControlSimulatorLaunchEnvironmentSimulatorUDID : self.simulator.udid,
    FBSimulatorControlSimulatorLaunchEnvironmentDeviceSetPath : self.simulator.set.deviceSet.setPath,
  };

  // Launch the Simulator.app Process.
  if (![self.launcher launchSimulatorProcessWithArguments:arguments environment:environment error:&innerError]) {
    return [FBSimulatorError failBoolWithError:innerError errorOut:error];
  }

  // Confirm that the Simulator is Booted.
  if (![self.simulator waitOnState:FBSimulatorStateBooted]) {
    return [[[FBSimulatorError
      describeFormat:@"Timed out waiting for device to be Booted, got %@", self.simulator.device.stateString]
      inSimulator:self.simulator]
      failBool:error];
  }

  // Expect the launch info for the process to exist.
  FBProcessInfo *containerApplication = [self.simulator.processFetcher simulatorApplicationProcessForSimDevice:self.simulator.device];
  if (!containerApplication) {
    return [[[FBSimulatorError
      describe:@"Could not obtain process info for container application"]
      inSimulator:self.simulator]
      failBool:error];
  }
  [self.simulator.eventSink containerApplicationDidLaunch:containerApplication];

  return YES;
}

- (BOOL)shouldLaunchSimulatorApplication
{
  return !self.configuration.shouldUseDirectLaunch;
}

@end

@implementation FBSimulatorBootStrategy

+ (instancetype)strategyWithConfiguration:(FBSimulatorBootConfiguration *)configuration simulator:(FBSimulator *)simulator
{
  id<FBCoreSimulatorBootOptions> coreSimulatorOptions = [self coreSimulatorBootOptionsWithConfiguration:configuration];
  FBCoreSimulatorBootStrategy *coreSimulatorStrategy = [[FBCoreSimulatorBootStrategy alloc] initWithConfiguration:configuration simulator:simulator options:coreSimulatorOptions];
  id<FBSimulatorApplicationProcessLauncher> launcher = [self applicationProcessLauncherWithConfiguration:configuration];
  id<FBSimulatorApplicationLaunchOptions> applicationOptions = [self applicationLaunchOptions];
  FBSimulatorApplicationLaunchStrategy *applicationStrategy = [[FBSimulatorApplicationLaunchStrategy alloc] initWithConfiguration:configuration simulator:simulator launcher:launcher options:applicationOptions];
  return [[FBSimulatorBootStrategy alloc] initWithConfiguration:configuration simulator:simulator applicationStrategy:applicationStrategy coreSimulatorStrategy:coreSimulatorStrategy];
}

+ (id<FBCoreSimulatorBootOptions>)coreSimulatorBootOptionsWithConfiguration:(FBSimulatorBootConfiguration *)configuration
{
  if (FBControlCoreGlobalConfiguration.isXcode9OrGreater) {
    return [[FBCoreSimulatorBootOptions_Xcode9 alloc] initWithConfiguration:configuration];
  } else if (FBControlCoreGlobalConfiguration.isXcode8OrGreater) {
    return [[FBCoreSimulatorBootOptions_Xcode8 alloc] initWithConfiguration:configuration];
  } else {
    return [FBCoreSimulatorBootOptions_Xcode7 new];
  }
}

+ (id<FBSimulatorApplicationProcessLauncher>)applicationProcessLauncherWithConfiguration:(FBSimulatorBootConfiguration *)configuration
{
  return configuration.shouldLaunchViaWorkspace
    ? [FBSimulatorApplicationProcessLauncher_Workspace new]
    : [FBSimulatorApplicationProcessLauncher_Task new];
}

+ (id<FBSimulatorApplicationLaunchOptions>)applicationLaunchOptions
{
  return [FBSimulatorApplicationLaunchOptions_Xcode7 new];
}

- (instancetype)initWithConfiguration:(FBSimulatorBootConfiguration *)configuration simulator:(FBSimulator *)simulator applicationStrategy:(FBSimulatorApplicationLaunchStrategy *)applicationStrategy coreSimulatorStrategy:(FBCoreSimulatorBootStrategy *)coreSimulatorStrategy
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _configuration = configuration;
  _simulator = simulator;
  _applicationStrategy = applicationStrategy;
  _coreSimulatorStrategy = coreSimulatorStrategy;

  return self;
}

- (BOOL)bootWithError:(NSError **)error
{
  // Return early depending on Simulator state.
  if (self.simulator.state == FBSimulatorStateBooted) {
    return YES;
  }
  if (self.simulator.state != FBSimulatorStateShutdown) {
    return [[[FBSimulatorError
      describeFormat:@"Cannot Boot Simulator when in %@ state", self.simulator.stateString]
      inSimulator:self.simulator]
      failBool:error];
  }

  // Boot via CoreSimulator.
  FBSimulatorConnection *connection = [self.coreSimulatorStrategy performBootWithError:error];
  if (!connection) {
    return NO;
  }

  // Launch the SimulatorApp Application.
  if (![self.applicationStrategy launchSimulatorApplicationWithError:error]) {
    return NO;
  }

  // Fail when the bridge could not be connected.
  NSError *innerError = nil;
  if (self.configuration.shouldConnectBridge) {
    FBSimulatorBridge *bridge = [connection connectToBridge:&innerError];
    if (!bridge) {
      return [FBSimulatorError failBoolWithError:innerError errorOut:error];
    }

    // Set the Location to a default location, when launched directly.
    // This is effectively done by Simulator.app by a NSUserDefault with for the 'LocationMode', even when the location is 'None'.
    // If the Location is set on the Simulator, then CLLocationManager will behave in a consistent manner inside launched Applications.
    [bridge setLocationWithLatitude:37.485023 longitude:-122.147911];
  }

  // Expect the launchd_sim process to be updated.
  if (![self launchdSimPresentWithAllRequiredServices:&innerError]) {
    return [FBSimulatorError failBoolWithError:innerError errorOut:error];
  }

  // Broadcast the availability of the new bridge.
  [self.simulator.eventSink connectionDidConnect:connection];

  return YES;
}

- (FBProcessInfo *)launchdSimPresentWithAllRequiredServices:(NSError **)error
{
  FBSimulatorProcessFetcher *processFetcher = self.simulator.processFetcher;
  FBProcessInfo *launchdProcess = [processFetcher launchdProcessForSimDevice:self.simulator.device];
  if (!launchdProcess) {
    return [[[FBSimulatorError
      describe:@"Could not obtain process info for launchd_sim process"]
      inSimulator:self.simulator]
      fail:error];
  }
  [self.simulator.eventSink simulatorDidLaunch:launchdProcess];

  // Return early if we're not awaiting services.
  if ((self.configuration.options & FBSimulatorBootOptionsAwaitServices) != FBSimulatorBootOptionsAwaitServices) {
    return launchdProcess;
  }

  // Now wait for the services.
  NSArray<NSString *> *requiredServiceNames = self.requiredLaunchdServicesToVerifyBooted;
  __block NSDictionary<id, NSString *> *processIdentifiers = @{};
  BOOL didStartAllRequiredServices = [NSRunLoop.mainRunLoop spinRunLoopWithTimeout:FBControlCoreGlobalConfiguration.slowTimeout untilTrue:^ BOOL {
    NSDictionary<NSString *, id> *services = [self.simulator.launchctl listServicesWithError:nil];
    if (!services) {
      return NO;
    }
    processIdentifiers = [NSDictionary dictionaryWithObjects:requiredServiceNames forKeys:[services objectsForKeys:requiredServiceNames notFoundMarker:NSNull.null]];
    if (processIdentifiers[NSNull.null]) {
      return NO;
    }
    return YES;
  }];
  if (!didStartAllRequiredServices) {
    return [[[FBSimulatorError
      describeFormat:@"Timed out waiting for service %@ to start", processIdentifiers[NSNull.null]]
      inSimulator:self.simulator]
      fail:error];
  }

  return launchdProcess;
}

/*
 A Set of launchd_sim service names that are used to determine whether relevant System daemons are available after booting.

 There is a period of time between when CoreSimulator says that the Simulator is 'Booted'
 and when it is stable enough state to launch Applications/Daemons, these Service Names
 represent the Services that are known to signify readyness.

 @return the required Service Names.
 */
- (NSArray<NSString *> *)requiredLaunchdServicesToVerifyBooted
{
  FBControlCoreProductFamily family = self.simulator.productFamily;
  if (family == FBControlCoreProductFamilyiPhone || family == FBControlCoreProductFamilyiPad) {
    if (FBControlCoreGlobalConfiguration.isXcode9OrGreater) {
      return @[
        @"com.apple.backboardd",
        @"com.apple.mobile.installd",
        @"com.apple.CoreSimulator.bridge",
        @"com.apple.SpringBoard",
      ];
    }
    if (FBControlCoreGlobalConfiguration.isXcode8OrGreater ) {
      return @[
        @"com.apple.backboardd",
        @"com.apple.mobile.installd",
        @"com.apple.SimulatorBridge",
        @"com.apple.SpringBoard",
      ];
    }
  }
  if (family == FBControlCoreProductFamilyAppleWatch || family == FBControlCoreProductFamilyAppleTV) {
    if (FBControlCoreGlobalConfiguration.isXcode8OrGreater) {
      return @[
        @"com.apple.mobileassetd",
        @"com.apple.nsurlsessiond",
      ];
    }
    return @[
      @"com.apple.mobileassetd",
      @"com.apple.networkd",
    ];
  }
  return @[];
}

@end
