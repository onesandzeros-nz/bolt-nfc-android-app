#import "NFCManager.h"
#import "React/RCTBridge.h"
#import "React/RCTConvert.h"
#import "React/RCTEventDispatcher.h"
#import "React/RCTLog.h"
#import "TapLinxLibrary.h"
#import "AES128Encryptor.h"
#import "MiFareCryptoHelper.h"
#import "CmacAesCipher.h"
#import "CmacCipher.h"
#import "TL_Utilities.h"
#import "NSMutableData+CmacPadding.h"

@implementation NfcManager {
  NSDictionary *nfcTechTypes;
  NSArray *techRequestTypes;
  RCTResponseSenderBlock techRequestCallback;
}

RCT_EXPORT_MODULE(MyReactModule)

@synthesize session;
@synthesize tagSession;
@synthesize libraryManager;
@synthesize apduHandler;
@synthesize desFireEV2;
@synthesize desFireWrapper;

static NSString *const kBgNfcTagNotification = @"RNBgNfcTagNotification";
NSArray * bgNdefRecords = nil;
 
+ (BOOL)application:(UIApplication *)application
continueUserActivity:(NSUserActivity *)userActivity
 restorationHandler:
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && (__IPHONE_OS_VERSION_MAX_ALLOWED >= 12000) /* __IPHONE_12_0 */
(nonnull void (^)(NSArray<id<UIUserActivityRestoring>> *_Nullable))restorationHandler {
#else
  (nonnull void (^)(NSArray *_Nullable))restorationHandler {
#endif
    if ([userActivity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb]) {
      if (@available(iOS 12.0, *)) {
        NFCNDEFMessage * ndefMessage = userActivity.ndefMessagePayload;
        if (ndefMessage != nil) {
          bgNdefRecords = [NfcManager convertNdefMessage: ndefMessage];
          [[NSNotificationCenter defaultCenter] postNotificationName:kBgNfcTagNotification
                                                              object:self
                                                            userInfo:nil];
        }
      }
    }
    return YES;
  }
  
  - (void)handleBgNfcTagNotification:(NSNotification *)notification
  {
    [self sendEventWithName:@"NfcManagerDiscoverBackgroundTag"
                       body:@{@"ndefMessage": bgNdefRecords}];
  }
  
  - (instancetype)init
  {
    if (self = [super init]) {
      NSLog(@"NfcManager created");
      [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(handleBgNfcTagNotification:)
                                                   name:kBgNfcTagNotification
                                                 object:nil];
    }
    
    if (@available(iOS 13.0, *)) {
      nfcTechTypes = @{
        [NSNumber numberWithInt: NFCTagTypeMiFare]: @"mifare",
        [NSNumber numberWithInt: NFCTagTypeFeliCa]: @"felica",
        [NSNumber numberWithInt: NFCTagTypeISO15693]: @"iso15693",
        // compatible with Android
        [NSNumber numberWithInt: NFCTagTypeISO7816Compatible]: @"IsoDep",
      };
    } else {
      nfcTechTypes = nil;
    }
    [self verifyLicense];
    
    libraryManager = [[MIFARELibraryManager alloc] init];
    apduHandler = [[MIFAREApduHandler alloc] init];
    
    // Set a delegate object that conforms to the MIFAREApduHandlerProtocol
    apduHandler.delegate = self;
    [libraryManager setApduHandlerWithApduHandler:apduHandler];
    
    //    desFireWrapper = [[TL_DESFireWrapper alloc] initMIFAREWithLibraryManager:libraryManager];
    //    desFireEV2 = [[TL_DESFireEV2 alloc] initDesFireEV2WithLibraryManager:libraryManager];
    return self;
  }
  
  - (void)reset
  {
    session = nil;
    tagSession = nil;
    techRequestTypes = nil;
    techRequestCallback = nil;
  }
  
  - (NSArray<NSString *> *)supportedEvents
  {
    return @[
      @"NfcManagerDiscoverTag",
      @"NfcManagerDiscoverBackgroundTag",
      @"NfcManagerSessionClosed",
      @"CreateBoltCard",
      @"NFCError"
    ];
  }
  
  + (NSDictionary*)convertNdefRecord:(NFCNDEFPayload *) record
  {
    return @{
      @"id": dataToArray([record identifier]),
      @"payload": dataToArray([record payload]),
      @"type": dataToArray([record type]),
      @"tnf": [NSNumber numberWithInt:[record typeNameFormat]]
    };
  }
  
  + (NSArray*)convertNdefMessage:(NFCNDEFMessage *)message
  {
    NSArray * records = [message records];
    NSMutableArray *resultArray = [NSMutableArray arrayWithCapacity: [records count]];
    for (int i = 0; i < [records count]; i++) {
      [resultArray addObject:[self convertNdefRecord: records[i]]];
    }
    return resultArray;
  }
  
  - (NSString*)getRNTechName:(id<NFCTag>)tag {
    NSString * tech = [nfcTechTypes objectForKey:[NSNumber numberWithInt:(int)tag.type]];
    if (tech == nil) {
      tech = @"unknown";
    }
    return tech;
  }
  
  - (NSData *)dataFromHexString:(NSString *)hexString {
    NSMutableData *data = [NSMutableData data];
    for (int i = 0; i < hexString.length; i += 2) {
      NSString *byteString = [hexString substringWithRange:NSMakeRange(i, 2)];
      NSScanner *scanner = [NSScanner scannerWithString:byteString];
      unsigned int byteValue;
      [scanner scanHexInt:&byteValue];
      uint8_t byte = (uint8_t)byteValue;
      [data appendBytes:&byte length:1];
    }
    return [NSData dataWithData:data];
  }
  
  - (NSDictionary*)getRNTag:(id<NFCTag>)tag {
    NSMutableDictionary *tagInfo = @{}.mutableCopy;
    NSString* tech = [self getRNTechName:tag];
    [tagInfo setObject:tech forKey:@"tech"];
    
    if (@available(iOS 13.0, *)) {
      if (tag.type == NFCTagTypeMiFare) {
        NSLog(@"tag type : NFCTagTypeMiFare");
        id<NFCMiFareTag> mifareTag = [tag asNFCMiFareTag];
        [tagInfo setObject:getHexString(mifareTag.identifier) forKey:@"id"];
      } else if (tag.type == NFCTagTypeISO7816Compatible) {
        NSLog(@"tag type : NFCTagTypeISO7816Compatible");
        id<NFCISO7816Tag> iso7816Tag = [tag asNFCISO7816Tag];
        
        //@TODO: REMOVE THIS CODE LATER
        //get iso select
        NSString *isoselectHex = @"00A4040007D276000085010100";
        NSData *isoSelectCommandData = [self dataFromHexString:isoselectHex];
        NFCISO7816APDU *isoSelectAPDU = [[NFCISO7816APDU alloc] initWithData:isoSelectCommandData];
        
        // Send the command to the tag
        [iso7816Tag sendCommandAPDU:isoSelectAPDU completionHandler:^(NSData * _Nonnull responseData, uint8_t sw1, uint8_t sw2, NSError * _Nullable error) {
          // Handle the response or error here
          if (error) {
            // Handle the error here
            NSLog(@"iso sendCommand Error: %@", [error localizedDescription]);
          } else {
            // Log the response
            NSString *responseString = [responseData description];
            NSLog(@"iso sendCommand Response: %@", responseString);
            NSLog(@"iso sendCommand sw1: %hhu", sw1);
            NSLog(@"iso sendCommand sw2: %hhu", sw2);
            
            // Process the response here
          }
        }];
        
        //get key version command
        unsigned char commandBytes[] = {0x90, 0x64, 0x00, 0x00, 0x01, 0x00, 0x00};
        
        // Convert the command bytes to an NSData object
        NSData *commandData = [NSData dataWithBytes:commandBytes length:sizeof(commandBytes)];
        NFCISO7816APDU *myAPDU = [[NFCISO7816APDU alloc] initWithData:commandData];
        
        // Send the command to the tag
        [iso7816Tag sendCommandAPDU:myAPDU completionHandler:^(NSData * _Nonnull responseData, uint8_t sw1, uint8_t sw2, NSError * _Nullable error) {
          // Handle the response or error here
          if (error) {
            // Handle the error here
            NSLog(@"sendCommand Error: %@", [error localizedDescription]);
          } else {
            // Log the response
            NSString *responseString = [responseData description];
            NSLog(@"sendCommand Response: %@", responseString);
            NSLog(@"sendCommand sw1: %hhu", sw1);
            NSLog(@"sendCommand sw2: %hhu", sw2);
            
            // Process the response here
          }
        }];
        
        //@TODO: REMOVE END
        
        [tagInfo setObject:getHexString(iso7816Tag.identifier) forKey:@"id"];
        [tagInfo setObject:iso7816Tag.initialSelectedAID forKey:@"initialSelectedAID"];
        [tagInfo setObject:dataToArray(iso7816Tag.historicalBytes) forKey:@"historicalBytes"];
        [tagInfo setObject:dataToArray(iso7816Tag.applicationData) forKey:@"applicationData"];
      } else if (tag.type == NFCTagTypeISO15693) {
        NSLog(@"tag type : NFCTagTypeISO15693");
        id<NFCISO15693Tag> iso15693Tag = [tag asNFCISO15693Tag];
        [tagInfo setObject:getHexString(iso15693Tag.identifier) forKey:@"id"];
        [tagInfo setObject:[NSNumber numberWithUnsignedInteger:iso15693Tag.icManufacturerCode] forKey:@"icManufacturerCode"];
        [tagInfo setObject:dataToArray(iso15693Tag.icSerialNumber) forKey:@"icSerialNumber"];
      } else if (tag.type == NFCTagTypeFeliCa) {
        NSLog(@"tag type : NFCTagTypeFeliCa");
        id<NFCFeliCaTag> felicaTag = [tag asNFCFeliCaTag];
        [tagInfo setObject:getHexString(felicaTag.currentIDm) forKey:@"idm"];
        [tagInfo setObject:getHexString(felicaTag.currentSystemCode) forKey:@"systemCode"];
      }
    }
    
    return tagInfo;
  }
  
  - (id<NFCNDEFTag>)getNDEFTagHandle:(id<NFCTag>)tag
  API_AVAILABLE(ios(13.0)) {
    // all following types inherite from NFCNDEFTag
    if (tag.type == NFCTagTypeMiFare) {
      return [tag asNFCMiFareTag];
    } else if (tag.type == NFCTagTypeISO7816Compatible) {
      return [tag asNFCISO7816Tag];
    } else if (tag.type == NFCTagTypeISO15693) {
      return [tag asNFCISO15693Tag];
    } else if (tag.type == NFCTagTypeFeliCa) {
      return [tag asNFCFeliCaTag];
    }
    
    return nil;
  }
  
  - (void)readerSession:(NFCNDEFReaderSession *)session didDetectNDEFs:(NSArray<NFCNDEFMessage *> *)messages
  {
    NSLog(@"readerSession:didDetectNDEFs");
    if ([messages count] > 0) {
      // parse the first message for now
      [self sendEventWithName:@"NfcManagerDiscoverTag"
                         body:@{@"ndefMessage": [NfcManager convertNdefMessage:messages[0]]}];
    } else {
      [self sendEventWithName:@"NfcManagerDiscoverTag"
                         body:@{@"ndefMessage": @[]}];
    }
  }
  
  - (void)readerSession:(NFCNDEFReaderSession *)session didInvalidateWithError:(NSError *)error
  {
    NSLog(@"readerSession:didInvalidateWithError: (%@)", [error localizedDescription]);
    [self reset];
    [self sendEventWithName:@"NfcManagerSessionClosed"
                       body:@{@"error": getErrorMessage(error)}];
  }
  
  - (void)tagReaderSession:(NFCTagReaderSession *)session didDetectTags:(NSArray<__kindof id<NFCTag>> *)tags
  API_AVAILABLE(ios(13.0)) {
    NSLog(@"NFCTag didDetectTags");
    if (techRequestCallback != nil) {
      for (id<NFCTag> tag in tags) {
        NSString * tagType = [self getRNTechName:tag];
        
        for (NSString* requestType in techRequestTypes) {
          // here we treat Ndef is a special case, because all specific tech types
          // inherites from NFCNDEFTag, so we simply allow it to connect
          if ([tagType isEqualToString:requestType] || [requestType isEqualToString:@"Ndef"]) {
            RCTResponseSenderBlock pendingCallback = techRequestCallback;
            techRequestCallback = nil;
            NSLog(@"tag type : %@", tagType);
            //                    switch (tagType) {
            //                        case "mifare": {
            //                            id<NFCMiFareTag> miFareTag = [tag asNFCMiFareTag];
            //                            NSLog(@"mifare family : %@", miFareTag.mifareFamily);
            //                            break;
            //                        }
            //                        case iso15693: {
            //                            id<NFCISO7816Tag> iso7816Tag = [tag asNFCISO7816Tag];
            //                            NSLog(@"NFCTagTypeISO15693");
            //                            break;
            //                        }
            //                        default:
            //                            break;
            //                    }
            [tagSession connectToTag:tag
                   completionHandler:^(NSError *error) {
              if (error != nil) {
                pendingCallback(@[getErrorMessage(error)]);
                return;
              }
              
              // Initialize the desFireEV2 object with the MIFARELibraryManager
              self.desFireEV2 = [[TL_DESFireEV2 alloc] initDesFireEV2WithLibraryManager:self.libraryManager];
              
              // Perform DESFire EV2 operations using desFireEV2 object methods
              [self.desFireEV2 getVersionOnCompletion:^(IOSByteArray *response, BOOL success) {
                if (success) {
                  NSLog(@"DESFire EV2 version: %@", response);
                } else {
                  NSLog(@"Failed to get DESFire EV2 version");
                }
              }];
              
              [self.desFireEV2 getCardUIDOnCompletion:^(IOSByteArray *response, BOOL success) {
                if (success) {
                  NSLog(@"DESFire card uid: %@", response);
                } else {
                  NSLog(@"Failed to get DESFire card uid");
                }
              }];
              
              pendingCallback(@[[NSNull null], requestType]);
            }];
            //                    [desFireEV2 getVersionOnCompletion:^(IOSByteArray * _Nonnull response, BOOL success) {
            //                      RCTLogInfo(@"getVersionOnCompletion %@", response);
            //                    }];
            //                    [desFireEV2 getCardUIDOnCompletion:^(IOSByteArray * _Nonnull response, BOOL success) {
            //                      RCTLogInfo(@"getCardUIDOnCompletion %@", response);
            //                    }];
            
          }
        }
      }
    }
  }
  
  - (void)tagReaderSession:(NFCTagReaderSession *)session didInvalidateWithError:(NSError *)error
  API_AVAILABLE(ios(13.0)) {
    NSLog(@"NFCTag didInvalidateWithError %@", getErrorMessage(error));
    if (techRequestCallback) {
      techRequestCallback(@[getErrorMessage(error)]);
      techRequestCallback = nil;
    }
    
    [self reset];
    [self sendEventWithName:@"NfcManagerSessionClosed"
                       body:@{@"error": getErrorMessage(error)}];
  }
  
  - (void)tagReaderSessionDidBecomeActive:(NFCTagReaderSession *)session
  API_AVAILABLE(ios(13.0)) {
    NSLog(@"NFCTag didBecomeActive");
  }
  
  - (NSData *)apduExchangeWithByteArray:(NSData *)apduData {
    NSMutableData *dataToReturn = [[NSMutableData alloc] init];
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    id<NFCTag> tag = nil;
    
    if (tagSession != nil) {
      if (tagSession.connectedTag) {
        tag = tagSession.connectedTag;
        switch (tag.type) {
          case NFCTagTypeMiFare: {
            id<NFCMiFareTag> miFareTag = [tag asNFCMiFareTag];
            [miFareTag sendMiFareCommand:apduData completionHandler:^(NSData * _Nullable responseData, NSError * _Nullable error) {            if (responseData) {                [dataToReturn setData:responseData];
            }
              dispatch_semaphore_signal(semaphore);
            }];
            break;
          }
          case NFCTagTypeISO15693: {
            id<NFCISO7816Tag> iso7816Tag = [tag asNFCISO7816Tag];
            NFCISO7816APDU *apdu = [[NFCISO7816APDU alloc] initWithData:apduData];
            [iso7816Tag sendCommandAPDU:apdu completionHandler:^(NSData * _Nullable responseData, uint8_t sw1, uint8_t sw2, NSError * _Nullable error) {            if (responseData) {                [dataToReturn setData:responseData];
            }
              [dataToReturn appendBytes:&sw1 length:1];
              [dataToReturn appendBytes:&sw2 length:1];
              dispatch_semaphore_signal(semaphore);
            }];
            break;
          }
          default:
            break;
        }
      }
    } else {
      NSLog(@"apduExchangeWithByteArray no session avail");
    }
    
    
    
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)));
    
    return dataToReturn;
    
  }
  
  + (BOOL)requiresMainQueueSetup
  {
    return YES;
  }
  
  - (void) verifyLicense
  {
    TapLinxLibrary *taplinxLibrary = [TapLinxLibrary sharedLibrary];
    
    //online license verification is not working atm
    //  [taplinxLibrary verifyLicense:@"87f293036c2e5cd0092055f45da295ed" WithCompletionHandler:^(BOOL isSuccess) {
    //      if (isSuccess) {
    //          // success
    //          RCTLogInfo(@"Verifing license success");
    //      } else {
    //          // failed
    //          RCTLogInfo(@"Verifing license failed");
    //      }
    //  }];
    
    NSString *key = @"IdHhqzL1Eyn/Q+iM7Al2ZMiMDr/atXGN6LI9Q3viETm0SWwdLYs8WHZZtUPRDeiAs59ae673SUlQoExOBOezsk5r9wcpSfp+dqRKAFqfeB2ck/ExVTabaRlWJ/MjprIzkFPMa6qwXidxFpoSm3yrWs3elanBCeyTUkDkoR0QjhheF8Y5Oi+fZ3dJVu53/eVy2LL0QbfOzzaY3CQsYxWa0/EHWLMMq7MpYJicKzUAwcJYi4YI/xVN4ATXeeGkimtgo9BTFWiP+wY8B1aq+3i4J51FkyLjCCFrWCESNClGKpfomICVHUbiJfxcXp8tm5UeiZXQTGag0SSMui03/frU2w==";
    NSData *decodedSignature = [[NSData alloc] initWithBase64EncodedString:key options:NSDataBase64DecodingIgnoreUnknownCharacters];
    
    if (decodedSignature == nil) {
      NSLog(@"Failed to decode signature");
      return;
    }
    
    BOOL verified = [taplinxLibrary doLocalVerificationWithSignature:decodedSignature];
    
    //@TODO: send RN a message
    if (verified) {
      // Code for verification success
      NSLog(@"Offline verification success");
    } else {
      // Code for verification failure
      NSLog(@"Offline verification failed");
    }
  }
  
  - (NSData *)rotateLeftByOneByte:(NSData *)data {
    NSUInteger length = [data length];
    uint8_t *bytes = (uint8_t *)[data bytes];
    uint8_t *rotated = malloc(length);
    for (NSInteger i = 0; i < length; i++) {
      NSInteger z = i - 1;
      if((long)z < 0) {
        z = length - 1;
      }
      rotated [z] =bytes[i];
    }
    NSData *result = [NSData dataWithBytes:rotated length:length];
    free(rotated);
    return result;
  }
  
  - (NSData *) evenNumberedBytes:(NSData *)byteData {
    NSUInteger length = [byteData length];
    uint8_t *bytes = (uint8_t *)[byteData bytes];
    uint8_t *evenBytes = malloc(length);
    for (NSInteger i = 0; i < length; i++) {
      NSInteger pos = i + 1;
      if (pos % 2) {
        //odd
//        NSInteger z = (pos - 1) / 2;
//        evenBytes [z] =bytes[i];
      }
      else {
        // even
        NSInteger z = (pos / 2) - 1;
        evenBytes [z] =bytes[i];
      }
    }
    NSData *result = [NSData dataWithBytes:evenBytes length:length / 2];
    free(evenBytes);
    return result;
  }

  -(NSData *) xorData:(NSData *) data1
            with:(NSData *)data2{
    const char *data1Bytes = [data1 bytes];
    const char *data2Bytes = [data2 bytes];
    // Mutable data that individual xor'd bytes will be added to
    NSMutableData *xorData = [[NSMutableData alloc] init];
    for (int i = 0; i < data1.length; i++){
        const char xorByte = data1Bytes[i] ^ data2Bytes[i];
        [xorData appendBytes:&xorByte length:1];
    }
    return xorData;
  }
  
  RCT_EXPORT_METHOD(initializeLib)
  {
    RCTLogInfo(@"Verifing license");
    TapLinxLibrary *taplinxLibrary = [TapLinxLibrary sharedLibrary];
    
    //online license verification is not working atm
    //  [taplinxLibrary verifyLicense:@"87f293036c2e5cd0092055f45da295ed" WithCompletionHandler:^(BOOL isSuccess) {
    //      if (isSuccess) {
    //          // success
    //          RCTLogInfo(@"Verifing license success");
    //      } else {
    //          // failed
    //          RCTLogInfo(@"Verifing license failed");
    //      }
    //  }];
    
    NSString *key = @"IdHhqzL1Eyn/Q+iM7Al2ZMiMDr/atXGN6LI9Q3viETm0SWwdLYs8WHZZtUPRDeiAs59ae673SUlQoExOBOezsk5r9wcpSfp+dqRKAFqfeB2ck/ExVTabaRlWJ/MjprIzkFPMa6qwXidxFpoSm3yrWs3elanBCeyTUkDkoR0QjhheF8Y5Oi+fZ3dJVu53/eVy2LL0QbfOzzaY3CQsYxWa0/EHWLMMq7MpYJicKzUAwcJYi4YI/xVN4ATXeeGkimtgo9BTFWiP+wY8B1aq+3i4J51FkyLjCCFrWCESNClGKpfomICVHUbiJfxcXp8tm5UeiZXQTGag0SSMui03/frU2w==";
    NSData *decodedSignature = [[NSData alloc] initWithBase64EncodedString:key options:NSDataBase64DecodingIgnoreUnknownCharacters];
    
    if (decodedSignature == nil) {
      NSLog(@"Failed to decode signature");
      return;
    }
    
    BOOL verified = [taplinxLibrary doLocalVerificationWithSignature:decodedSignature];
    
    //@TODO: send RN a message
    if (verified) {
      // Code for verification success
      NSLog(@"Offline verification success");
    } else {
      // Code for verification failure
      NSLog(@"Offline verification failed");
    }
  }
  
  RCT_EXPORT_METHOD(getBackgroundNdef: (nonnull RCTResponseSenderBlock)callback)
  {
    if (bgNdefRecords != nil) {
      callback(@[[NSNull null], bgNdefRecords]);
    } else {
      callback(@[[NSNull null], [NSNull null]]);
    }
  }
  
  RCT_EXPORT_METHOD(clearBackgroundNdef: (nonnull RCTResponseSenderBlock)callback)
  {
    bgNdefRecords = nil;
    callback(@[[NSNull null]]);
  }
  
  RCT_EXPORT_METHOD(isSupported: (NSString *)tech callback:(nonnull RCTResponseSenderBlock)callback)
  {
    if ([tech isEqualToString:@""] || [tech isEqualToString:@"Ndef"]) {
      if (@available(iOS 11.0, *)) {
        callback(@[[NSNull null], NFCNDEFReaderSession.readingAvailable ? @YES : @NO]);
        return;
      }
    } else if ([tech isEqualToString:@"mifare"] || [tech isEqualToString:@"felica"] || [tech isEqualToString:@"iso15693"] || [tech isEqualToString:@"IsoDep"]) {
      if (@available(iOS 13.0, *)) {
        callback(@[[NSNull null], NFCTagReaderSession.readingAvailable ? @YES : @NO]);
        return;
      }
    }
    
    callback(@[[NSNull null], @NO]);
  }
  
  RCT_EXPORT_METHOD(start: (nonnull RCTResponseSenderBlock)callback)
  {
    if (@available(iOS 11.0, *)) {
      if (NFCNDEFReaderSession.readingAvailable) {
        NSLog(@"NfcManager initialized");
        [self reset];
        callback(@[]);
        return;
      }
    }
    
    callback(@[@"Not support in this device", [NSNull null]]);
  }
  
  RCT_EXPORT_METHOD(requestTechnology: (NSArray *)techs options: (NSDictionary *)options callback:(nonnull RCTResponseSenderBlock)callback)
  {
    if (@available(iOS 13.0, *)) {
      if (tagSession == nil && session == nil) {
        NFCPollingOption pollFlags = NFCPollingISO14443 | NFCPollingISO15693;
        if ([techs containsObject:@"felica"]) {
          pollFlags |= NFCPollingISO18092;
        }
        tagSession = [[NFCTagReaderSession alloc]
                      initWithPollingOption:pollFlags delegate:self queue:dispatch_get_main_queue()];
        //            tagSession.alertMessage = [options objectForKey:@"alertMessage"];
        [tagSession beginSession];
        techRequestTypes = techs;
        techRequestCallback = callback;
      } else {
        callback(@[@"Duplicated registration", [NSNull null]]);
      }
    } else {
      callback(@[@"Not support in this device", [NSNull null]]);
    }
  }
  
  RCT_EXPORT_METHOD(cancelTechnologyRequest:(nonnull RCTResponseSenderBlock)callback)
  {
    if (@available(iOS 13.0, *)) {
      if (tagSession != nil) {
        [tagSession invalidateSession];
        callback(@[]);
      } else {
        callback(@[@"Not even registered", [NSNull null]]);
      }
    } else {
      callback(@[@"Not support in this device", [NSNull null]]);
    }
  }
  
  RCT_EXPORT_METHOD(registerTagEvent:(NSDictionary *)options callback:(nonnull RCTResponseSenderBlock)callback)
  {
    if (@available(iOS 11.0, *)) {
      if (session == nil && tagSession == nil) {
        session = [[NFCNDEFReaderSession alloc]
                   initWithDelegate:self queue:dispatch_get_main_queue() invalidateAfterFirstRead:[[options objectForKey:@"invalidateAfterFirstRead"] boolValue]];
        session.alertMessage = [options objectForKey:@"alertMessage"];
        [session beginSession];
        callback(@[]);
      } else {
        callback(@[@"Duplicated registration", [NSNull null]]);
      }
    } else {
      callback(@[@"Not support in this device", [NSNull null]]);
    }
  }
  
  RCT_EXPORT_METHOD(unregisterTagEvent:(nonnull RCTResponseSenderBlock)callback)
  {
    if (@available(iOS 11.0, *)) {
      if (session != nil) {
        [session invalidateSession];
        callback(@[]);
      } else {
        callback(@[@"Not even registered", [NSNull null]]);
      }
    } else {
      callback(@[@"Not support in this device", [NSNull null]]);
    }
  }
  
  RCT_EXPORT_METHOD(invalidateSession:(nonnull RCTResponseSenderBlock)callback)
  {
    if (@available(iOS 13.0, *)) {
      if (session != nil) {
        [session invalidateSession];
        callback(@[]);
      } else if (tagSession != nil) {
        [tagSession invalidateSession];
        callback(@[]);
      } else {
        callback(@[@"No active session", [NSNull null]]);
      }
    }
  }
  
  RCT_EXPORT_METHOD(invalidateSessionWithError:(NSString *)errorMessage callback:(nonnull RCTResponseSenderBlock)callback)
  {
    if (@available(iOS 13.0, *)) {
      if (session != nil) {
        [session invalidateSessionWithErrorMessage: errorMessage];
        callback(@[]);
      } else if (tagSession != nil) {
        [tagSession invalidateSessionWithErrorMessage: errorMessage];
        callback(@[]);
      } else {
        callback(@[@"No active session", [NSNull null]]);
      }
    }
  }
  
  RCT_EXPORT_METHOD(getTag: (nonnull RCTResponseSenderBlock)callback)
  {
    if (@available(iOS 13.0, *)) {
      NSMutableDictionary* rnTag = @{}.mutableCopy;
      id<NFCNDEFTag> ndefTag = nil;
      
      if (tagSession != nil) {
        if (tagSession.connectedTag) {
          rnTag = [self getRNTag:tagSession.connectedTag].mutableCopy;
          ndefTag = [self getNDEFTagHandle:tagSession.connectedTag];
        }
      } else {
        callback(@[@"No session available", [NSNull null]]);
      }
      
      if (ndefTag) {
        [ndefTag readNDEFWithCompletionHandler:^(NFCNDEFMessage *ndefMessage, NSError *error) {
          if (!error) {
            [rnTag setObject:[NfcManager convertNdefMessage:ndefMessage] forKey:@"ndefMessage"];
          }
          callback(@[[NSNull null], rnTag]);
        }];
        return;
      }
      
      callback(@[[NSNull null], rnTag]);
    } else {
      callback(@[@"Not support in this device", [NSNull null]]);
    }
  }
  
  RCT_EXPORT_METHOD(getNdefMessage: (nonnull RCTResponseSenderBlock)callback)
  {
    if (@available(iOS 13.0, *)) {
      id<NFCNDEFTag> ndefTag = nil;
      
      if (tagSession != nil) {
        if (tagSession.connectedTag) {
          ndefTag = [self getNDEFTagHandle:tagSession.connectedTag];
        }
      }
      
      if (ndefTag) {
        [ndefTag readNDEFWithCompletionHandler:^(NFCNDEFMessage *ndefMessage, NSError *error) {
          if (error) {
            callback(@[getErrorMessage(error), [NSNull null]]);
          } else {
            callback(@[[NSNull null], @{@"ndefMessage": [NfcManager convertNdefMessage:ndefMessage]}]);
          }
        }];
        return;
      }
      
      callback(@[@"No ndef available", [NSNull null]]);
    } else {
      callback(@[@"Not support in this device", [NSNull null]]);
    }
  }
  
  RCT_EXPORT_METHOD(writeNdefMessage:(NSArray*)bytes callback:(nonnull RCTResponseSenderBlock)callback)
  {
    if (@available(iOS 13.0, *)) {
      id<NFCNDEFTag> ndefTag = nil;
      
      if (tagSession != nil) {
        if (tagSession.connectedTag) {
          ndefTag = [self getNDEFTagHandle:tagSession.connectedTag];
        }
      }
      
      if (ndefTag) {
        NSData *data = arrayToData(bytes);
        NFCNDEFMessage *ndefMsg = [NFCNDEFMessage ndefMessageWithData:data];
        if (!ndefMsg) {
          callback(@[@"invalid ndef msg"]);
          return;
        }
        
        [ndefTag writeNDEF:ndefMsg completionHandler:^(NSError *error) {
          if (error) {
            callback(@[getErrorMessage(error), [NSNull null]]);
          } else {
            callback(@[[NSNull null]]);
          }
        }];
        return;
      }
      
      callback(@[@"No ndef available", [NSNull null]]);
    } else {
      callback(@[@"Not support in this device", [NSNull null]]);
    }
  }
  
  RCT_EXPORT_METHOD(makeReadOnly:(nonnull RCTResponseSenderBlock)callback)
  {
    if (@available(iOS 13.0, *)) {
      id<NFCNDEFTag> ndefTag = nil;
      
      if (tagSession != nil) {
        if (tagSession.connectedTag) {
          ndefTag = [self getNDEFTagHandle:tagSession.connectedTag];
        }
      }
      
      if (ndefTag) {
        [ndefTag writeLockWithCompletionHandler:^(NSError *error) {
          if (error) {
            callback(@[getErrorMessage(error), [NSNull null]]);
          } else {
            callback(@[[NSNull null]]);
          }
        }];
        return;
      }
      
      callback(@[@"No ndef available", [NSNull null]]);
    } else {
      callback(@[@"Not support in this device", [NSNull null]]);
    }
  }
  
  RCT_EXPORT_METHOD(queryNDEFStatus:(nonnull RCTResponseSenderBlock)callback)
  {
    if (@available(iOS 13.0, *)) {
      id<NFCNDEFTag> ndefTag = nil;
      
      if (tagSession != nil) {
        if (tagSession.connectedTag) {
          ndefTag = [self getNDEFTagHandle:tagSession.connectedTag];
        }
      }
      
      if (ndefTag) {
        [ndefTag queryNDEFStatusWithCompletionHandler:^(NFCNDEFStatus status, NSUInteger capacity, NSError *error) {
          if (error) {
            callback(@[getErrorMessage(error), [NSNull null]]);
          } else {
            callback(@[[NSNull null],
                       @{
                         @"status": [[NSNumber alloc] initWithInt:(int)status],
                         @"capacity": [[NSNumber alloc] initWithInt:(int)capacity]
                       }
                     ]);
          }
        }];
        return;
      }
      
      callback(@[@"No ndef available", [NSNull null]]);
    } else {
      callback(@[@"Not support in this device", [NSNull null]]);
    }
  }
  
  RCT_EXPORT_METHOD(setAlertMessage: (NSString *)alertMessage callback:(nonnull RCTResponseSenderBlock)callback)
  {
    if (@available(iOS 11.0, *)) {
      if (session != nil) {
        session.alertMessage = alertMessage;
        callback(@[]);
      } else if (tagSession != nil) {
        tagSession.alertMessage = alertMessage;
        callback(@[]);
      } else {
        callback(@[@"Not even registered", [NSNull null]]);
      }
    } else {
      callback(@[@"Not support in this device", [NSNull null]]);
    }
  }
  
  RCT_EXPORT_METHOD(isSessionAvailable:(nonnull RCTResponseSenderBlock)callback)
  {
    if (@available(iOS 11.0, *)) {
      callback(@[[NSNull null], session != nil ? @YES : @NO]);
    } else {
      callback(@[@"Not support in this device", [NSNull null]]);
    }
  }
  
  RCT_EXPORT_METHOD(isTagSessionAvailable:(nonnull RCTResponseSenderBlock)callback)
  {
    if (@available(iOS 11.0, *)) {
      callback(@[[NSNull null], tagSession != nil ? @YES : @NO]);
    } else {
      callback(@[@"Not support in this device", [NSNull null]]);
    }
  }
  
  RCT_EXPORT_METHOD(writeBoltcard:(NSArray*)ndefBytes callback:(nonnull RCTResponseSenderBlock)callback)
  {
    if (tagSession != nil) {
      if (!tagSession.connectedTag) {
        callback(@[@"No connected tag", [NSNull null]]);
      }
      id<NFCTag> tag = tagSession.connectedTag;
      NSMutableDictionary *tagInfo = @{}.mutableCopy;
      NSString* tech = [self getRNTechName:tag];
      [tagInfo setObject:tech forKey:@"tech"];
      
      if (@available(iOS 13.0, *)) {
        if (tag.type == NFCTagTypeISO7816Compatible) {
          NSLog(@"tag type : NFCTagTypeISO7816Compatible");
          id<NFCISO7816Tag> iso7816Tag = [tag asNFCISO7816Tag];
          
          NSString *isoselectHex = @"00A4040007D276000085010100";
          NSData *isoSelectCommandData = [self dataFromHexString:isoselectHex];
          NFCISO7816APDU *isoSelectAPDU = [[NFCISO7816APDU alloc] initWithData:isoSelectCommandData];
          
          // Send the command to the tag (ISO SELECT)
          [iso7816Tag sendCommandAPDU:isoSelectAPDU completionHandler:^(NSData * _Nonnull responseData, uint8_t sw1, uint8_t sw2, NSError * _Nullable error) {
            // Handle the response or error here
            if (error) {
              // Handle the error here
              NSLog(@"iso sendCommand Error: %@", [error localizedDescription]);
            } else {
              // Log the response
              NSString *responseString = [responseData description];
              NSLog(@"iso sendCommand Response: %@", responseString);
              NSLog(@"iso sendCommand sw1: %X", sw1);
              NSLog(@"iso sendCommand sw2: %X", sw2);
              
              // Process the response here
            }
            //AUTHENTICATEEV2FIRST (Part 1)
            NSString *firstAuthHex = @"9071000005000300000000";
            NSData *firstAuthCommandData = [self dataFromHexString:firstAuthHex];
            NFCISO7816APDU *firstAuthAPDU = [[NFCISO7816APDU alloc] initWithData:firstAuthCommandData];
            
            NSLog(@"firstAuth Command data: %@", firstAuthCommandData);
            NSLog(@"firstAuth APDU: %@", firstAuthAPDU);
            
            // Send the command to the tag
            [iso7816Tag sendCommandAPDU:firstAuthAPDU completionHandler:^(NSData * _Nonnull RndBEnc, uint8_t sw1, uint8_t sw2, NSError * _Nullable error) {
              // Handle the response or error here
              if (error) {
                // Handle the error here
                NSLog(@"firstAuthAPDU sendCommand Error: %@", [error localizedDescription]);
              } else {
                // Log the response
                NSString *responseString = [RndBEnc description];
                NSLog(@"firstAuthAPDU sendCommand Response: %@", responseString);
                NSLog(@"firstAuthAPDU sendCommand sw1: %X", sw1);
                NSLog(@"firstAuthAPDU sendCommand sw2: %X", sw2);
                
              }
              
              //AUTHENTICATEEV2FIRST (Part 2)
              // @TODO: check if sw1 == "91" && sw2 == "AF"
              
              //default AES 128 keys - 16 bytes of 0
              NSData *keyAes128Default = [self dataFromHexString:@"00000000000000000000000000000000"];
              
              //According to doc, for the encryption during authentication the IV will be 128 bits of 0 == 16 bytes of 0
              NSMutableData *iv = [[NSMutableData alloc] initWithLength:16];
              
              
              // Create an instance of the MiFareCryptoHelper class
              //this is another way of encrypting/decrypting using the Mifare taplinx library
              //it is giving out the same output as the one I wrote though (AES128Encryptor)
              MiFareCryptoHelper *cryptoHelper = [[MiFareCryptoHelper alloc] init];

              CCOperation operation = kCCDecrypt;
              CCOptions options = kCCOptionECBMode | kCCModeCBC;
              // Call the doAESCipher function
              NSData *cipherText = [cryptoHelper doAESCipher:RndBEnc
                                                         key:keyAes128Default
                                                     context:operation
                                                      option:&options
                                                    initialV:iv];
              
              NSLog(@"cipherText %@", cipherText);
              
              
              //decrypt the response data from the first auth to get RndB
              NSData *RndB = [AES128Encryptor decrypt:RndBEnc key:keyAes128Default iv:iv];
              
              // Generate a random 16-byte value for RndA
              uint8_t randomBytes[16];
              arc4random_buf(randomBytes, 16);
              NSData *RndA = [NSData dataWithBytes:randomBytes length:16];
              
              // Get the response of the rotateLeftByOneByte function
              NSData *RndBRotl = [self rotateLeftByOneByte:RndB];
              
              NSLog(@"keyAes128Default %@", keyAes128Default);
              NSLog(@"iv %@", iv);
              NSLog(@"RndBEnc %@", RndBEnc);
              NSLog(@"RndB %@", RndB);
              NSLog(@"RndBRotl %@", RndBRotl);
              NSLog(@"RndA %@", RndA);
              
              //concat RndA and RndBRotl
              NSMutableData *RndARndBRotl = [RndA mutableCopy];
              [RndARndBRotl appendData:RndBRotl];
              
              NSLog(@"RndARndBRotl %@", RndARndBRotl);
              
              //encrypt RndA + RndBRotl using AES 128 encryption
              NSData *RndARndBEnc = [AES128Encryptor encrypt:RndARndBRotl key:keyAes128Default iv:iv];
              
              
              NSData *secondAuthCommandStart = [self dataFromHexString:@"90AF000020"];
              NSMutableData *secondAuthCommandData = [secondAuthCommandStart mutableCopy];
              // Append the encrypted data
              [secondAuthCommandData appendData:RndARndBEnc];
              // Append "00" as a hex string
              [secondAuthCommandData appendData:[self dataFromHexString:@"00"]];
              
              NSLog(@"RndARndBEnc: %@", RndARndBEnc);
              
              NFCISO7816APDU *secondAuthAPDU = [[NFCISO7816APDU alloc] initWithData:secondAuthCommandData];
              
              NSLog(@"secondAuth command data: %@", secondAuthCommandData);
              NSLog(@"secondAuth APDU: %@", secondAuthAPDU);
              
              
              // Send the command to the tag
              [iso7816Tag sendCommandAPDU:secondAuthAPDU completionHandler:^(NSData * _Nonnull responseData, uint8_t sw1, uint8_t sw2, NSError * _Nullable error) {
                // Handle the response or error here
                if (error) {
                  // Handle the error here
                  NSLog(@"secondAuth sendCommand Error: %@", [error localizedDescription]);
                } else {
                  // Log the response
                  NSString *responseString = [responseData description];
                  NSLog(@"secondAuth sendCommand Response: %@", responseString);
                  TL_Utilities *utility = [TL_Utilities sharedUtility];
//                  NSData *responseHex = [self dataFromHexString:responseString];
                  
//                  NSString *responseString = [utility dataToHexString:responseData];
                  NSLog(@"secondAuthresponseData: %@", responseData);
//                  NSLog(@"secondAuthresponseHex: %@", responseHex);
                  NSData *secondAuthResponseDecrypt = [AES128Encryptor decrypt:responseData key:keyAes128Default iv:iv];
                  NSLog(@"secondAuthResponseDecrypt: %@", secondAuthResponseDecrypt);
                  NSData *ti = [secondAuthResponseDecrypt subdataWithRange:NSMakeRange(0, 4)];
                  NSLog(@"secondAuth sendCommand sw1: %X", sw1);
                  NSLog(@"secondAuth sendCommand sw2: %X", sw2);
                  NSLog(@"ti: %@", ti);
                  
                  // Process the response here

                  //get file settings
                  NSData *getFileSettingsCommandStart = [self dataFromHexString:@"90F500000902"];
                  NSMutableData *getFileSettingsCommandData = [getFileSettingsCommandStart mutableCopy];
                  
                  
                  //SV1 = SV 1 = [0xA5][0x5A][0x00][0x01][0x00][0x80][RndA[15:14] || [ (RndA[13:8] ⊕ RndB[15:10]) ] || [RndB[9:0] || RndA[7:0]
                  //# == XOR-operator
                  NSData *sv1Start = [self dataFromHexString:@"A55A00010080"];
                  NSMutableData *sv1 = [sv1Start mutableCopy];

                  [sv1 appendData:[RndA subdataWithRange:NSMakeRange(0, 2)]];

                  NSData *sv1XorData = [self xorData:[RndA subdataWithRange:NSMakeRange(2, 6)] with:[RndB subdataWithRange:NSMakeRange(0, 6)]];
                  [sv1 appendData:sv1XorData];
                  [sv1 appendData:[RndB subdataWithRange:NSMakeRange(6, 10)]];
                  [sv1 appendData:[RndA subdataWithRange:NSMakeRange(8, 8)]];

                  NSLog(@"sv1: %@", sv1);

                  //SV2 = 5Ah||A5h||00h||01h||00h||80h||RndA[15..14]|| ( RndA[13..8] # RndB[15..10])||RndB[9..0]||RndA[7..0]
                  //# == XOR-operator
                  

                  NSData *sv2Start = [self dataFromHexString:@"5AA500010080"];
                  NSMutableData *sv2 = [sv2Start mutableCopy];

                  [sv2 appendData:[RndA subdataWithRange:NSMakeRange(0, 2)]];

                  NSData *svXorData = [self xorData:[RndA subdataWithRange:NSMakeRange(2, 6)] with:[RndB subdataWithRange:NSMakeRange(0, 6)]];
                  [sv2 appendData:svXorData];
                  [sv2 appendData:[RndB subdataWithRange:NSMakeRange(6, 10)]];
                  [sv2 appendData:[RndA subdataWithRange:NSMakeRange(8, 8)]];

                  NSLog(@"sv2: %@", sv2);
                  
                  CmacCipher *cmacKey = [[CmacCipher alloc] initWithCipher: [CmacAesCipher createCipherAesCbcNoPaddingForOperation:kCCEncrypt withKey:keyAes128Default keySize:16 andIv:iv]];
                  [cmacKey update:sv2];
                  NSData *sesAuthMacKey = [cmacKey doFinal];
                  NSString *sesAuthMacKeyStr = [utility dataToHexString:sesAuthMacKey];
                  NSLog(@"sesAuthMacKeyStr :%@", sesAuthMacKeyStr);
//                  NSData *sesAuthMacKeyFinal = [self dataFromHexString:sesAuthMacKeyStr];
//
//                  NSLog(@"sesAuthMacKey: %@", sesAuthMacKeyFinal);

                  CmacCipher *commandMacCipher = [[CmacCipher alloc] initWithCipher: [CmacAesCipher createCipherAesCbcNoPaddingForOperation:kCCEncrypt withKey:sesAuthMacKey keySize:16 andIv:iv]];
                  NSLog(@"commandMacCipher :%@", commandMacCipher);
                  NSData *commandMacHexStart = [self dataFromHexString:@"F50000"];
                  NSMutableData *commandMacHex = [commandMacHexStart mutableCopy];
                  [commandMacHex appendData:ti];
                  [commandMacHex appendData:[self dataFromHexString:@"02"]];
                  [commandMacHex appendIso7816d4Padding : 8];
                  [commandMacCipher update:commandMacHex];
                  NSData *commandMac = [commandMacCipher doFinal];
                  NSLog(@"commandMacHex: %@", commandMacHex);
                  NSLog(@"commandMac: %@", commandMac);
                  NSString *commandMacStr = [utility dataToHexString:commandMac];
                  NSLog(@"commandMacStr :%@", commandMacStr);
                  NSData *tuncatedMac = [self evenNumberedBytes:commandMac];
                  NSLog(@"tuncatedMac :%@", tuncatedMac);
                  
                  [getFileSettingsCommandData appendData:tuncatedMac];
                  [getFileSettingsCommandData appendData:[self dataFromHexString:@"00"]];
                  
                  
                  //TEST sv2 (test it with the examples provided in the doc)
                  
//                  NSData *testRndA = [self dataFromHexString:@"13C5DB8A5930439FC3DEF9A4C675360F"];
//                  NSData *testRndB = [self dataFromHexString:@"B9E2FC789B64BF237CCCAA20EC7E6E48"];
//                  NSData *testsv2Start = [self dataFromHexString:@"5AA500010080"];
//                  NSMutableData *testsv2 = [testsv2Start mutableCopy];
//
//                  [testsv2 appendData:[testRndA subdataWithRange:NSMakeRange(0, 2)]];
//
//                  NSData *testsvXorData = [self xorData:[testRndA subdataWithRange:NSMakeRange(2, 6)] with:[testRndB subdataWithRange:NSMakeRange(0, 6)]];
//                  [testsv2 appendData:testsvXorData];
//                  [testsv2 appendData:[testRndB subdataWithRange:NSMakeRange(6, 10)]];
//                  [testsv2 appendData:[testRndA subdataWithRange:NSMakeRange(8, 8)]];
//                  NSLog(@"TEST sv2: %@", testsv2);
//
//
//                  CmacCipher *testCmac = [[CmacCipher alloc] initWithCipher: [CmacAesCipher createCipherAesCbcNoPaddingForOperation:kCCEncrypt withKey:keyAes128Default keySize:16 andIv:iv]];
//                  [testCmac update:testsv2];
//                  NSData *testFullMac = [testCmac doFinal];
//                  NSLog(@"TEST cmac final: %@", testFullMac);
                  
//                  NSData *testSesAuthMacKey = [self dataFromHexString:@"8248134A386E86EB7FAF54A52E536CB6"];
//
//                  CmacCipher *testcommandMacCipher = [[CmacCipher alloc] initWithCipher: [CmacAesCipher createCipherAesCbcNoPaddingForOperation:kCCEncrypt withKey:testSesAuthMacKey keySize:16 andIv:iv]];
//                  NSLog(@"testcommandMacCipher :%@", testcommandMacCipher);
//                  NSMutableData *testCommandMacHex = [commandMacHexStart mutableCopy];
//                  [testCommandMacHex appendData:[self dataFromHexString:@"7A21085E"]];
//                  //0000000000000000
//                  [testCommandMacHex appendData:[self dataFromHexString:@"02"]];
//                  [testCommandMacHex appendIso7816d4Padding : 8];
//                  [testcommandMacCipher update:testCommandMacHex];
//                  NSData *testCommandMac = [testcommandMacCipher doFinal];
//                  NSLog(@"test commandMacHex: %@", testCommandMacHex);
//                  NSLog(@"test commandMac: %@", testCommandMac);
//                  NSString *testCommandMacStr = [utility dataToHexString:testCommandMac];
//                  NSLog(@"test commandMacStr :%@", testCommandMacStr);
//                  NSData *testTuncatedMac = [self evenNumberedBytes:testCommandMac];
//                  NSLog(@"test tuncatedMac :%@", testTuncatedMac);
//
//                  NSMutableData *testGetFileSettingsCommandData = [getFileSettingsCommandStart mutableCopy];
//                  [testGetFileSettingsCommandData appendData:testTuncatedMac];
//                  [testGetFileSettingsCommandData appendData:[self dataFromHexString:@"00"]];
//                  NSLog(@"testGetFileSettingsCommandData :%@", testGetFileSettingsCommandData);
                  
                  //TEST END
                  
                  NSLog(@"getFileSettingsCommandData: %@", getFileSettingsCommandData);
                  
                  NFCISO7816APDU *getFileSettingsAPDU = [[NFCISO7816APDU alloc] initWithData:getFileSettingsCommandData];
                  
                  NSLog(@"getFileSettingsAPDU: %@", getFileSettingsAPDU);

                  [iso7816Tag sendCommandAPDU:getFileSettingsAPDU completionHandler:^(NSData * _Nonnull responseData, uint8_t sw1, uint8_t sw2, NSError * _Nullable error) {
                    // Handle the response or error here
                    if (error) {
                      // Handle the error here
                      NSLog(@"get file settings sendCommand Error: %@", [error localizedDescription]);
                    } else {
                      // Log the response
                      NSString *responseString = [responseData description];
                      NSLog(@"getFileSettings sendCommand Response: %@", responseString);
                      NSLog(@"getFileSettings sendCommand sw1: %X", sw1);
                      NSLog(@"getFileSettings sendCommand sw2: %X", sw2);

                      //try
                    }
                  }];

                }
                callback(@[[NSNull null]]);
                return;
              }];
            }];
          }];
          
        } else {
          callback(@[@"tag type not supported"]);
        }
        
        //Update the code so the ndef write doesn't happen for now. It seems like if the ndef write happens in the middle of authenticating, we get "c1" response (illegal command code)
        return;
        
        //write ndef
        id<NFCNDEFTag> ndefTag = nil;
        
        if (tagSession != nil) {
          if (tagSession.connectedTag) {
            ndefTag = [self getNDEFTagHandle:tagSession.connectedTag];
          }
        }
        
        if (ndefTag) {
          NSData *data = arrayToData(ndefBytes);
          NFCNDEFMessage *ndefMsg = [NFCNDEFMessage ndefMessageWithData:data];
          if (!ndefMsg) {
            callback(@[@"invalid ndef msg"]);
            return;
          }
          
          [ndefTag writeNDEF:ndefMsg completionHandler:^(NSError *error) {
            if (error) {
              callback(@[getErrorMessage(error), [NSNull null]]);
            } else {
              
              //ndef write successful
              //try authenticating
              
              
              callback(@[[NSNull null]]);
            }
          }];
          return;
        }
        
        callback(@[@"No ndef available", [NSNull null]]);
      } else {
        callback(@[@"Not support in this device", [NSNull null]]);
      }
    } else {
      callback(@[@"No session available", [NSNull null]]);
    }
    
    
  }
  
  @end
  
