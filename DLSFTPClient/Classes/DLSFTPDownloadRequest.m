//
//  DLSFTPDownloadRequest.m
//  DLSFTPClient
//
//  Created by Dan Leehr on 3/7/13.
//  Copyright (c) 2013 Dan Leehr. All rights reserved.
//

#import "DLSFTPDownloadRequest.h"
#import "DLSFTPConnection.h"
#import "DLSFTPFile.h"
#import "NSDictionary+SFTPFileAttributes.h"

//Constants
static const size_t cBufferSize = 8192;



@interface DLSFTPDownloadRequest ()

@property (nonatomic, copy) DLSFTPClientProgressBlock progressBlock;
@property (nonatomic, copy) NSString *remotePath;
@property (nonatomic, copy) NSString *localPath;
@property (nonatomic, strong) NSDate *startTime;
@property (nonatomic, strong) NSDate *finishTime;
@property (nonatomic, strong) DLSFTPFile *downloadedFile;
@property (nonatomic) BOOL shouldResume;

@property (nonatomic) dispatch_io_t channel;
@property (nonatomic) dispatch_semaphore_t semaphore;
@property (nonatomic) dispatch_source_t progressSource;

// does this make sense to have in the base class?
@property (nonatomic, assign) LIBSSH2_SFTP_HANDLE *handle;

@end

@implementation DLSFTPDownloadRequest

@synthesize progressSource=_progressSource;
@synthesize channel=_channel;
@synthesize semaphore=_semaphore;

- (id)initWithConnection:(DLSFTPConnection *)connection
              remotePath:(NSString *)remotePath
               localPath:(NSString *)localPath
            shouldresume:(BOOL)shouldResume
            successBlock:(DLSFTPClientFileTransferSuccessBlock)successBlock
            failureBlock:(DLSFTPClientFailureBlock)failureBlock
           progressBlock:(DLSFTPClientProgressBlock)progressBlock {
    self = [super initWithConnection:connection];
    if (self) {
        self.remotePath = remotePath;
        self.localPath = localPath;
        self.shouldResume = shouldResume;
        self.successBlock = successBlock;
        self.failureBlock = failureBlock;
        self.progressBlock = progressBlock;
    }
    return self;
}

- (void)dealloc {
#if NEEDS_DISPATCH_RETAIN_RELEASE
    if (_progressSource) {
        dispatch_release(_progressSource);
        _progressSource = NULL;
    }
    if (_semaphore) {
        dispatch_release(_semaphore);
        _semaphore = NULL;
    }
    if (_channel) {
        dispatch_release(_channel);
        _progressSource = NULL;
    }
#endif
}


- (BOOL)openFileHandle {
    LIBSSH2_SESSION *session = [self.connection session];
    LIBSSH2_SFTP *sftp = [self.connection sftp];
    int socketFD = [self.connection socket];
    LIBSSH2_SFTP_HANDLE *handle = NULL;
    while (   (handle = libssh2_sftp_open(sftp, [self.remotePath UTF8String], LIBSSH2_FXF_READ, 0)) == NULL
           && (libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN)
           && self.isCancelled == NO) {
        waitsocket(socketFD, session);
    }
    if (handle == NULL) {
        // unable to open
        unsigned long lastError = libssh2_sftp_last_error([self.connection sftp]);
        NSString *errorDescription = [NSString stringWithFormat:@"Unable to open file for reading: SFTP Status Code %ld", lastError];
        self.error = [self errorWithCode:eSFTPClientErrorUnableToOpenFile
                        errorDescription:errorDescription
                         underlyingError:@(lastError)];
        return NO;
    } else {
        self.handle = handle;
        return YES;
    }
}

- (void)start {
    if ([self pathIsValid:self.localPath] == NO) { return; }
    if ([self pathIsValid:self.remotePath] == NO) { return; }
    if ([self ready] == NO) { return; }
    unsigned long long resumeOffset = 0ull;
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.localPath] == NO) {
        // File does not exist, create it
        [[NSFileManager defaultManager] createFileAtPath:self.localPath
                                                contents:nil
                                              attributes:nil];
    } else {
        // local file exists, get existing size
        NSError *error = nil;
        NSDictionary *localAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:self.localPath
                                                                                         error:&error];
        if (error) {
            self.error = [self errorWithCode:eSFTPClientErrorUnableToReadFile
                            errorDescription:@"Unable to get attributes (file size) of existing file"
                             underlyingError:@(error.code)];
            return;
        }

        if(self.shouldResume) {
            resumeOffset = [localAttributes fileSize];
        }
    }

    if ([[NSFileManager defaultManager] isWritableFileAtPath:self.localPath] == NO) {
        self.error = [self errorWithCode:eSFTPClientErrorUnableToOpenLocalFileForWriting
                        errorDescription:@"Local file is not writable"
                         underlyingError:nil];
        return;
    }

    if([self checkSftp] == NO) { return; }
    LIBSSH2_SESSION *session = [self.connection session];
    int socketFD = [self.connection socket];

    if ([self openFileHandle] == NO) { return; }

    // file handle is now open
    LIBSSH2_SFTP_ATTRIBUTES attributes;
    // stat the file
    int result;
    while (  ((result = libssh2_sftp_fstat(self.handle, &attributes)) == LIBSSH2SFTP_EAGAIN)
           && self.isCancelled == NO) {
        waitsocket(socketFD, session);
    }
    // can also check permissions/types
    if (result) {
        // unable to stat the file
        NSString *errorDescription = [NSString stringWithFormat:@"Unable to stat file: SFTP Status Code %d", result];
        self.error = [self errorWithCode:eSFTPClientErrorUnableToStatFile
                        errorDescription:errorDescription
                         underlyingError:@(result)];
        return;
    }

    // Create the file object here since we have the attributes.  Only used by successBlock
    NSDictionary *attributesDictionary = [NSDictionary dictionaryWithAttributes:attributes];
    DLSFTPFile *file = [[DLSFTPFile alloc] initWithPath:self.remotePath
                                             attributes:attributesDictionary];
    self.downloadedFile = file;

    if (self.shouldResume) {
        libssh2_sftp_seek64(self.handle, resumeOffset);
    }

    self.semaphore = dispatch_semaphore_create(0);

    /* Begin dispatch io */
    {
        void(^cleanup_handler)(int) = ^(int error) {
            if (error) {
                printf("Error creating channel: %d", error);
            }
            NSLog(@"finished writing file for download, cleaning up channel");
            dispatch_semaphore_signal(self.semaphore);
        };

        int oflag;
        if (self.shouldResume) {
            oflag =   O_APPEND
            | O_WRONLY
            | O_CREAT;
        } else {
            oflag =   O_WRONLY
            | O_CREAT
            | O_TRUNC;
        }

        dispatch_io_t channel = dispatch_io_create_with_path(  DISPATCH_IO_STREAM
                                                             , [self.localPath UTF8String]
                                                             , oflag
                                                             , 0
                                                             , dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,  0   )
                                                             , cleanup_handler
                                                             );
        if (channel == NULL) {
            // Error creating the channel
            NSString *errorDescription = [NSString stringWithFormat:@"Unable to create a channel for writing to %@", self.localPath];
            self.error = [self errorWithCode:eSFTPClientErrorUnableToCreateChannel
                            errorDescription:errorDescription
                             underlyingError:nil];
            return;
        } else {
            self.channel = channel;
        }
    }
    /* dispatch_io has been created */

    // configure progress source
    {
        dispatch_source_t progressSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
        __block unsigned long long bytesReceived = resumeOffset;
        unsigned long long filesize = attributes.filesize;
        __weak DLSFTPDownloadRequest *weakSelf = self;
        dispatch_source_set_event_handler(progressSource, ^{
            bytesReceived += dispatch_source_get_data(progressSource);
            if (weakSelf.progressBlock) {
                weakSelf.progressBlock(bytesReceived, filesize);
            }
        });
        dispatch_source_set_cancel_handler(progressSource, ^{
#if NEEDS_DISPATCH_RETAIN_RELEASE
            dispatch_release(progressSource);
#endif
        });
        self.progressSource = progressSource;
        dispatch_resume(self.progressSource);
    } // end of progressSource setup

    self.startTime = [NSDate date];
    // start the first download block
    __weak DLSFTPDownloadRequest *weakSelf = self;
    dispatch_async(dispatch_get_current_queue(), ^{ [weakSelf downloadChunk]; });
}

- (void)downloadChunk {
    // better to subclass DLSFTPRequest, then requests can have properties
    int bytesRead = 0;
    static char buffer[cBufferSize];
    while (   self.isCancelled == NO
           && (bytesRead = libssh2_sftp_read(self.handle, buffer, cBufferSize)) == LIBSSH2SFTP_EAGAIN) {
        waitsocket([self.connection socket], [self.connection session]);
        if (self.isCancelled) {
            printf("request is cancelled after waitsocket\n");
        }
    }
    if (self.isCancelled) { return; }
    // after data has been read, write it to the channel
    __weak DLSFTPDownloadRequest *weakSelf = self;
    if (bytesRead > 0) {
        dispatch_source_merge_data(self.progressSource, bytesRead);
        dispatch_data_t data = dispatch_data_create(buffer, bytesRead, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        dispatch_io_write(  self.channel
                          , 0
                          , data
                          , dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)
                          , ^(bool done, dispatch_data_t data, int error) {
                              // done refers to the chunk of data written
                              // Tried moving progress reporting here, didn't make much difference
                              if (error) {
                                  printf("error in dispatch_io_write %d\n", error);
                              }
                          });
#if NEEDS_DISPATCH_RETAIN_RELEASE
        dispatch_release(data);
#endif
        // read the next chunk
        dispatch_async(dispatch_get_current_queue(), ^{ [weakSelf downloadChunk]; });
    } else if(bytesRead == 0) {
        dispatch_async(dispatch_get_current_queue(), ^{ [weakSelf downloadFinished]; });
    } else { //bytesRead < 0
        dispatch_async(dispatch_get_current_queue(), ^{ [weakSelf downloadFailed]; });
    }
}

- (void)downloadFinished {
    // nothing read, done
    self.finishTime = [NSDate date];
    dispatch_source_cancel(self.progressSource);
    dispatch_io_close(self.channel, 0);

    /* End dispatch_io */

    dispatch_semaphore_wait(self.semaphore, DISPATCH_TIME_FOREVER);
#if NEEDS_DISPATCH_RETAIN_RELEASE
    dispatch_release(self.semaphore);
#endif
    int socketFD = [self.connection socket];
    LIBSSH2_SESSION *session = [self.connection session];
    if (self.isCancelled) {
        // cancelled by user
        while(libssh2_sftp_close_handle(self.handle) == LIBSSH2SFTP_EAGAIN) {
            waitsocket(socketFD, session);
        }

        // delete the file if not resumable
        if (self.shouldResume == NO) {
            NSError __autoreleasing *deleteError = nil;
            if([[NSFileManager defaultManager] removeItemAtPath:self.localPath error:&deleteError] == NO) {
                NSLog(@"Unable to delete unfinished file: %@", deleteError);
            }
        }
        self.error = [self errorWithCode:eSFTPClientErrorCancelledByUser
                        errorDescription:@"Cancelled by user."
                         underlyingError:nil];
        return;
    }

    // now close the remote handle
    int result = 0;
    while((result = libssh2_sftp_close_handle(self.handle)) == LIBSSH2SFTP_EAGAIN) {
        waitsocket(socketFD, session);
    }
    if (result) {
        NSString *errorDescription = [NSString stringWithFormat:@"Close file handle failed with code %d", result];
        self.error = [self errorWithCode:eSFTPClientErrorUnableToCloseFile
                        errorDescription:errorDescription
                         underlyingError:nil];
        return;
    }
}

- (void)downloadFailed {
    // get the error before closing the file
    int result = libssh2_sftp_last_error([self.connection sftp]);
    int socketFD = [self.connection socket];
    LIBSSH2_SESSION *session = [self.connection session];
    while(libssh2_sftp_close_handle(self.handle) == LIBSSH2SFTP_EAGAIN) {
        waitsocket(socketFD, session);
    }
    // error reading
    NSString *errorDescription = [NSString stringWithFormat:@"Read file failed with code %d.", result];
    self.error = [self errorWithCode:eSFTPClientErrorUnableToReadFile
                    errorDescription:errorDescription
                     underlyingError:@(result)];
}


- (void)finish {
    DLSFTPClientFileTransferSuccessBlock successBlock = self.successBlock;
    DLSFTPFile *downloadedFile = self.downloadedFile;
    NSDate *startTime = self.startTime;
    NSDate *finishTime = self.finishTime;
    if (successBlock) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            successBlock(downloadedFile,startTime,finishTime);
        });
    }
    self.successBlock = nil;
    self.failureBlock = nil;
}

@end