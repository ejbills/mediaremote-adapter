// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <unistd.h>

#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

#import "MediaRemote.h"
#import "MediaRemoteAdapter.h"
#import "MediaRemoteAdapterKeys.h"

static CFRunLoopRef _runLoop = NULL;
static dispatch_queue_t _queue;
static dispatch_block_t _debounce_block = NULL;
static NSString *_targetBundleIdentifier = NULL;
static pid_t _parentPID = 0;
static dispatch_source_t _parentMonitorTimer = NULL;

// These keys identify a now playing item uniquely.
static NSArray<NSString *> *identifyingItemKeys(void) {
    return @[ (NSString *)kTitle, (NSString *)kArtist, (NSString *)kAlbum ];
}

static void printOut(NSString *message) {
    fprintf(stdout, "%s\n", [message UTF8String]);
    fflush(stdout);
}

static void printErr(NSString *message) {
    fprintf(stderr, "%s\n", [message UTF8String]);
    fflush(stderr);
}

static NSString *formatError(NSError *error) {
    return
        [NSString stringWithFormat:@"%@ (%@:%ld)", [error localizedDescription],
                                   [error domain], (long)[error code]];
}

static NSString *serializeData(NSDictionary *data, BOOL diff) {
    NSError *error;
    NSDictionary *wrappedData = @{
        @"type" : @"data",
        @"diff" : @(diff),
        @"payload" : data,
    };
    NSData *serialized = [NSJSONSerialization dataWithJSONObject:wrappedData
                                                         options:0
                                                           error:&error];
    if (!serialized) {
        printErr([NSString stringWithFormat:@"Failed for serialize data: %@",
                                            formatError(error)]);
        return nil;
    }
    return [[NSString alloc] initWithData:serialized
                                 encoding:NSUTF8StringEncoding];
}

static NSMutableDictionary *
convertNowPlayingInformation(NSDictionary *information) {
    NSMutableDictionary *data = [NSMutableDictionary dictionary];

    void (^setKey)(id, id) = ^(id key, id fromKey) {
      id value = [NSNull null];
      if (information != nil) {
          id result =
              information[fromKey];
          if (result != nil) {
              value = result;
          }
      }
      [data setObject:value forKey:key];
    };

    void (^setValue)(id, id (^)(void)) = ^(id key, id (^evaluate)(void)) {
      id value = nil;
      if (information != nil) {
          value = evaluate();
      }
      if (value != nil) {
          [data setObject:value forKey:key];
      } else {
          [data setObject:[NSNull null] forKey:key];
      }
    };

    setKey((NSString *)kTitle, (id)kMRMediaRemoteNowPlayingInfoTitle);
    setKey((NSString *)kArtist, (id)kMRMediaRemoteNowPlayingInfoArtist);
    setKey((NSString *)kAlbum, (id)kMRMediaRemoteNowPlayingInfoAlbum);
    setValue((NSString *)kDurationMicros, ^id {
      id duration =
          information[(NSString *)kMRMediaRemoteNowPlayingInfoDuration];
      if (duration != nil) {
          NSTimeInterval durationMicros = [duration doubleValue] * 1000 * 1000;
          if (isinf(durationMicros) || isnan(durationMicros)) {
              return nil;
          }
          return @(floor(durationMicros));
      }
      return nil;
    });
    setValue((NSString *)kElapsedTimeMicros, ^id {
      id elapsedTimeValue =
          information[(NSString *)kMRMediaRemoteNowPlayingInfoElapsedTime];
      if (elapsedTimeValue != nil) {
          NSTimeInterval elapsedTimeMicros =
              [elapsedTimeValue doubleValue] * 1000 * 1000;
          if (isinf(elapsedTimeMicros) || isnan(elapsedTimeMicros)) {
              return nil;
          }
          return @(floor(elapsedTimeMicros));
      }
      return nil;
    });
    setValue((NSString *)kTimestampEpochMicros, ^id {
      NSDate *timestampValue =
          information[(NSString *)kMRMediaRemoteNowPlayingInfoTimestamp];
      if (timestampValue != nil) {
          NSTimeInterval timestampEpoch = [timestampValue timeIntervalSince1970];
          NSTimeInterval timestampEpochMicro = timestampEpoch * 1000 * 1000;
          return @(floor(timestampEpochMicro));
      }
      return nil;
    });
    setKey((NSString *)kArtworkMimeType,
           (id)kMRMediaRemoteNowPlayingInfoArtworkMIMEType);
    setValue((NSString *)kArtworkDataBase64, ^id {
      NSData *artworkDataValue =
          (NSData *)information[(NSString *)kMRMediaRemoteNowPlayingInfoArtworkData];
      if (artworkDataValue != nil) {
          return [artworkDataValue base64EncodedStringWithOptions:0];
      }
      return nil;
    });
    setValue((NSString *)kShuffleMode, ^id {
      NSNumber *mode = information[(NSString *)kMRMediaRemoteNowPlayingInfoShuffleMode];
      return mode;
    });
    setValue((NSString *)kRepeatMode, ^id {
      NSNumber *mode = information[(NSString *)kMRMediaRemoteNowPlayingInfoRepeatMode];
      return mode;
    });
    setValue((NSString *)kPlaybackRate, ^id {
      NSNumber *rate = information[(NSString *)kMRMediaRemoteNowPlayingInfoPlaybackRate];
      return rate;
    });

    return data;
}

static NSDictionary *createDiff(NSDictionary *a, NSDictionary *b) {
    NSMutableDictionary *diff = [NSMutableDictionary dictionary];
    NSMutableSet *allKeys = [NSMutableSet setWithArray:a.allKeys];
    [allKeys addObjectsFromArray:b.allKeys];
    for (id key in allKeys) {
        id oldValue = a[key];
        id newValue = b[key];
        if (![oldValue isEqual:newValue]) {
            diff[key] = newValue ?: [NSNull null];
        }
    }
    return [diff copy];
}

static bool isSameItemIdentity(NSDictionary *a, NSDictionary *b) {
    for (NSString *key in identifyingItemKeys()) {
        id aValue = a[key];
        id bValue = b[key];
        if (aValue == nil || bValue == nil || ![aValue isEqual:bValue]) {
            return false;
        }
    }
    return true;
}

// Always sends the full data payload. No more diffing.
static void printData(NSDictionary *data) {
    NSString *serialized = serializeData(data, false);
    if (serialized != nil) {
        printOut(serialized);
    }
}

static void appForPID(int pid, void (^block)(NSRunningApplication *)) {
    if (pid <= 0) return;
    NSRunningApplication *process =
        [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (process != nil && process.bundleIdentifier != nil) {
        block(process);
    }
}

// Centralized function to process track info.
// It converts, filters, and prints the final JSON data.
static void processNowPlayingInfo(NSDictionary *nowPlayingInfo, BOOL isPlaying, NSRunningApplication *application) {
    if (nowPlayingInfo == nil || [nowPlayingInfo count] == 0) {
        printOut(@"NIL");
        return;
    }
    id title = nowPlayingInfo[(NSString *)kMRMediaRemoteNowPlayingInfoTitle];
    if (title == nil || title == [NSNull null] || ([title isKindOfClass:[NSString class]] && [(NSString *)title length] == 0)) return;

    // If a target bundle ID is set, filter out notifications from other apps.
    if (_targetBundleIdentifier && application && ![application.bundleIdentifier isEqual:_targetBundleIdentifier]) {
        return;
    }

    NSMutableDictionary *data = convertNowPlayingInformation(nowPlayingInfo);
    [data setObject:@(isPlaying) forKey:(NSString *)kIsPlaying];
    if (application) {
        data[(NSString *)kBundleIdentifier] = application.bundleIdentifier;
        data[(NSString *)kApplicationName] = application.localizedName;
        data[(NSString *)kPID] = [NSString stringWithFormat:@"%d", application.processIdentifier];
    }

    printData(data);
}

// Fetches all necessary information (track info, playing state, PID)
// and passes it to the processing function.
static void fetchAndProcess(int pid) {
    MRMediaRemoteGetNowPlayingInfo(_queue, ^(CFDictionaryRef information) {
        if (information == NULL) {
            return; // No media playing, do nothing.
        }
        NSDictionary *infoDict = [(__bridge NSDictionary *)information copy];
        MRMediaRemoteGetNowPlayingApplicationIsPlaying(_queue, ^(Boolean isPlaying) {
            void (^processWithPid)(int) = ^(int finalPid) {
                if (finalPid > 0) {
                    __block bool appFound = false;
                    appForPID(finalPid, ^(NSRunningApplication *process) {
                        appFound = true;
                        processNowPlayingInfo(infoDict, isPlaying, process);
                    });
                    if (!appFound) {
                        processNowPlayingInfo(infoDict, isPlaying, nil);
                    }
                } else {
                    processNowPlayingInfo(infoDict, isPlaying, nil);
                }
            };

            if (pid > 0) {
                processWithPid(pid);
            } else {
                MRMediaRemoteGetNowPlayingApplicationPID(_queue, ^(int fetchedPid) {
                    processWithPid(fetchedPid);
                });
            }
        });
    });
}

// Check if parent process is still alive
static void checkParentProcess(void) {
    if (_parentPID > 0) {
        // Use kill(pid, 0) to check if process exists without sending a signal
        if (kill(_parentPID, 0) != 0) {
            // Parent process is dead, terminate this process
            printErr(@"Parent process died, terminating");
            exit(0);
        }
    }
}

// Set up periodic parent process monitoring
static void setupParentMonitoring(void) {
    _parentPID = getppid(); // Get parent process ID

    // Create a timer that checks parent process every 5 seconds
    _parentMonitorTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    if (_parentMonitorTimer) {
        dispatch_source_set_timer(_parentMonitorTimer,
                                 dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                                 5 * NSEC_PER_SEC,
                                 1 * NSEC_PER_SEC);

        dispatch_source_set_event_handler(_parentMonitorTimer, ^{
            checkParentProcess();
        });

        dispatch_resume(_parentMonitorTimer);
    }
}

// C function implementations to be called from Perl
void bootstrap(void) {
    _queue = dispatch_queue_create("mediaremote-adapter", DISPATCH_QUEUE_SERIAL);

    // Read the target bundle identifier from the environment variable.
    // This is set by the Perl script based on the `--id` command-line argument.
    const char *bundleIdEnv = getenv("MEDIAREMOTEADAPTER_bundle_identifier");
    if (bundleIdEnv != NULL) {
        _targetBundleIdentifier = [NSString stringWithUTF8String:bundleIdEnv];
    }

    // Set up parent process monitoring
    setupParentMonitoring();
}

void loop(void) {
    _runLoop = CFRunLoopGetCurrent();

    MRMediaRemoteRegisterForNowPlayingNotifications(
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));

    // --- Initial Fetch ---
    // Fetch the current state immediately when the loop starts, so we don't
    // have to wait for a media change event.
    // We schedule this on our serial queue to ensure the run loop is active.
    dispatch_async(_queue, ^{
        fetchAndProcess(0);
    });

    void (^handler)(NSNotification *) = ^(NSNotification *notification) {
      // If there's an existing block scheduled, cancel it.
      if (_debounce_block) {
          dispatch_block_cancel(_debounce_block);
      }

      // Create a new block to be executed after the delay.
      _debounce_block = dispatch_block_create(0, ^{
          id pidValue = notification.userInfo[(NSString *)kMRMediaRemoteNowPlayingApplicationPIDUserInfoKey];
          int pid = (pidValue != nil) ? [pidValue intValue] : 0;
          fetchAndProcess(pid);
      });
      
      // Schedule the new block to run after a 100ms delay.
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), _queue, _debounce_block);
    };
    
    [[NSNotificationCenter defaultCenter]
        addObserverForName:(NSString *)kMRMediaRemoteNowPlayingInfoDidChangeNotification
                    object:nil
                     queue:nil
                usingBlock:handler];

    CFRunLoopRun();
}

void play(void) {
    MRMediaRemoteSendCommand(kMRPlay, nil);
}

void pause_command(void) {
    MRMediaRemoteSendCommand(kMRPause, nil);
}

void toggle_play_pause(void) {
    MRMediaRemoteSendCommand(kMRTogglePlayPause, nil);
}

void next_track(void) {
    MRMediaRemoteSendCommand(kMRNextTrack, nil);
}

void previous_track(void) {
    MRMediaRemoteSendCommand(kMRPreviousTrack, nil);
}

void stop_command(void) {
    MRMediaRemoteSendCommand(kMRStop, nil);
}

void set_time_from_env(void) {
    const char *timeStr = getenv("MEDIAREMOTE_SET_TIME");
    if (timeStr == NULL) {
        return;
    }

    double time = atof(timeStr);
    MRMediaRemoteSetElapsedTime(time);
}

void set_shuffle_mode(void) {
    const char *modeStr = getenv("MEDIAREMOTE_SET_SHUFFLE_MODE");
    if (modeStr == NULL) {
        return;
    }

    int mode = atoi(modeStr);
    MRMediaRemoteSetShuffleMode(mode);
}

void set_repeat_mode(void) {
    const char *modeStr = getenv("MEDIAREMOTE_SET_REPEAT_MODE");
    if (modeStr == NULL) {
        return;
    }

    int mode = atoi(modeStr);
    MRMediaRemoteSetRepeatMode(mode);
}

void get(void) {
    __block BOOL completed = NO;

    MRMediaRemoteGetNowPlayingInfo(_queue, ^(CFDictionaryRef information) {
        if (information == NULL) {
            printOut(@"NIL");
            completed = YES;
            return;
        }
        NSDictionary *infoDict = [(__bridge NSDictionary *)information copy];
        MRMediaRemoteGetNowPlayingApplicationIsPlaying(_queue, ^(Boolean isPlaying) {
            MRMediaRemoteGetNowPlayingApplicationPID(_queue, ^(int fetchedPid) {
                if (fetchedPid > 0) {
                    __block bool appFound = false;
                    appForPID(fetchedPid, ^(NSRunningApplication *process) {
                        appFound = true;
                        processNowPlayingInfo(infoDict, isPlaying, process);
                    });
                    if (!appFound) {
                        processNowPlayingInfo(infoDict, isPlaying, nil);
                    }
                } else {
                    processNowPlayingInfo(infoDict, isPlaying, nil);
                }
                completed = YES;
            });
        });
    });

    // Wait for completion with timeout
    NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while (!completed && [[NSDate date] compare:timeout] == NSOrderedAscending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
} 