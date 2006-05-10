/*
 Copyright (c) 2005, Greg Hulands <ghulands@framedphotographics.com>
 All rights reserved.
 
 
 Redistribution and use in source and binary forms, with or without modification, 
 are permitted provided that the following conditions are met:
 
 
 Redistributions of source code must retain the above copyright notice, this list 
 of conditions and the following disclaimer.
 
 Redistributions in binary form must reproduce the above copyright notice, this 
 list of conditions and the following disclaimer in the documentation and/or other 
 materials provided with the distribution.
 
 Neither the name of Greg Hulands nor the names of its contributors may be used to 
 endorse or promote products derived from this software without specific prior 
 written permission.
 
 
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY 
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES 
 OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT 
 SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, 
 INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED 
 TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR 
 BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY 
 WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 
 */

#import "StreamBasedConnection.h"
#import "InterThreadMessaging.h"
#import "RunLoopForwarder.h"
#import "NSData+Connection.h"
#import <sys/types.h> 
#import <sys/socket.h> 
#import <netinet/in.h>

const unsigned int kStreamChunkSize = 2048;
NSString *StreamBasedErrorDomain = @"StreamBasedErrorDomain";

@interface StreamBasedConnection (Private)
- (void)checkQueue;
- (void)processFileCheckingQueue;
- (void)recalcUploadSpeedWithBytesSent:(unsigned)length;
- (void)recalcDownloadSpeedWithBytesSent:(unsigned)length;
@end

@implementation StreamBasedConnection

- (id)initWithHost:(NSString *)host
			  port:(NSString *)port
		  username:(NSString *)username
		  password:(NSString *)password
			 error:(NSError **)error
{
	if (self = [super initWithHost:host port:port username:username password:password error:error])
	{
		_port = [[NSPort port] retain];
		_forwarder = [[RunLoopForwarder alloc] init];
		[_forwarder setReturnValueDelegate:self];
		_sendBufferLock = [[NSLock alloc] init];
		_sendBuffer = [[NSMutableData data] retain];
		_createdThread = [NSThread currentThread];
		
		[_port setDelegate:self];
		[NSThread prepareForConnectionInterThreadMessages];
		_runThread = YES;
		[NSThread detachNewThreadSelector:@selector(runBackgroundThread:)
								 toTarget:self
							   withObject:nil];
	}
	
	return self;
}

- (void)dealloc
{
	[self closeStreams];
	[self sendPortMessage:KILL_THREAD];
	[_port setDelegate:nil];
    [_port release];
	[_forwarder release];
	[_sendStream release];
	[_receiveStream release];
	[_sendBufferLock release];
	[_sendBuffer release];
	[_fileCheckingConnection setDelegate:nil];
	[_fileCheckingConnection forceDisconnect];
	[_fileCheckingConnection release];
	[_fileCheckInFlight release];
	[_lastChunkSent release];
	[_lastChunkReceived release];
	
	[super dealloc];
}

#pragma mark -
#pragma mark Accessors

- (void)setSendStream:(NSStream *)stream
{
	if (stream != _sendStream) {
		[_sendStream autorelease];
		_sendStream = [stream retain];
	}
}

- (void)setReceiveStream:(NSStream *)stream
{
	if (stream != _receiveStream) {
		[_receiveStream autorelease];
		_receiveStream = [stream retain];
	}
}

- (NSStream *)sendStream
{
	return _sendStream;
}

- (NSStream *)receiveStream
{
	return _receiveStream;
}

- (unsigned)localPort
{
	CFSocketNativeHandle native;
	CFDataRef nativeProp = CFReadStreamCopyProperty ((CFReadStreamRef)_receiveStream, kCFStreamPropertySocketNativeHandle);
	if (nativeProp == NULL)
	{
		return -1;
	}
	CFDataGetBytes (nativeProp, CFRangeMake(0, CFDataGetLength(nativeProp)), (UInt8 *)&native);
	CFRelease (nativeProp);
	struct sockaddr sock;
	socklen_t len = sizeof(sock);
	
	if (getsockname(native, &sock, &len) >= 0) {
		return ntohs(((struct sockaddr_in *)&sock)->sin_port);
	}
	
	return native;
}

#pragma mark -
#pragma mark Threading Support

- (void)runloopForwarder:(RunLoopForwarder *)rlw returnedValue:(void *)value 
{
	//by default we do nothing, subclasses are implementation specific based on their current state
}

/*!	The main background thread loop.  It runs continuously whether connected or not.
*/
- (void)runBackgroundThread:(id)notUsed
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	[NSThread prepareForConnectionInterThreadMessages];
	_bgThread = [NSThread currentThread];
	// NOTE: this may be leaking ... there are two retains going on here.  Apple bug report #2885852, still open after TWO YEARS!
	// But then again, we can't remove the thread, so it really doesn't mean much.	
	[[NSRunLoop currentRunLoop] addPort:_port forMode:NSDefaultRunLoopMode];
	NSAutoreleasePool *loop;
	
	while (_runThread)
	{
		loop = [[NSAutoreleasePool alloc] init];
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
		[NSThread sleepUntilDate:[NSDate distantPast]];
		[loop release];
	}
	_bgThread = nil;
	
	[pool release];
}

- (void)sendPortMessage:(int)aMessage
{
	//NSAssert([NSThread currentThread] == _mainThread, @"must be called from the main thread");
	if (nil != _port)
	{
		NSPortMessage *message
		= [[NSPortMessage alloc] initWithSendPort:_port
									  receivePort:_port components:nil];
		[message setMsgid:aMessage];
		
		@try {
			if ([NSThread currentThread] != _bgThread)
			{
				BOOL sent = [message sendBeforeDate:[NSDate dateWithTimeIntervalSinceNow:15.0]];
				if (!sent)
				{
					KTLog(ThreadingDomain, KTLogFatal, @"StreamBasedConnection couldn't send message %d", aMessage);
				}
			}
			else
			{
				[self handlePortMessage:message];
			}
		} @catch (NSException *ex) {
			KTLog(ThreadingDomain, KTLogError, @"%@", ex);
		} @finally {
			[message release];
		} 
	}
}

- (void)scheduleStreamsOnRunLoop
{
	[_receiveStream setDelegate:self];
	[_sendStream setDelegate:self];
	
	[_receiveStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
	[_sendStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
	
	[_receiveStream open];
	[_sendStream open];
}

/*" NSPortDelegate method gets called in the background thread.
"*/
- (void)handlePortMessage:(NSPortMessage *)portMessage
{
    int message = [portMessage msgid];
	
	switch (message)
	{
		case CONNECT:
		{
			[self scheduleStreamsOnRunLoop];
			break;
		}
		case COMMAND:
		{
			[self checkQueue];
			break;
		}
		case ABORT:
			break;
			
		case DISCONNECT:
			if (_flags.didDisconnect)
			{
				[_forwarder connection:self didDisconnectFromHost:[self host]];
			}
			break;
			
		case FORCE_DISCONNECT:
			break;
		case CHECK_FILE_QUEUE:
			[self processFileCheckingQueue];
			break;
		case KILL_THREAD:
		{
			[self closeStreams];
			[[NSRunLoop currentRunLoop] removePort:_port forMode:NSDefaultRunLoopMode];
			_runThread = NO;
			break;
		}
	}
}

#pragma mark -
#pragma mark Queue Support

- (void)endBulkCommands
{
	[super endBulkCommands];
	[self sendPortMessage:COMMAND];
}

- (void)queueCommand:(id)command
{
	[super queueCommand:command];
	
	if (!_flags.inBulk) {
		if ([NSThread currentThread] != _bgThread)
		{
			[self sendPortMessage:COMMAND];		// State has changed, check if we can handle message.
		}
		else
		{
			[self checkQueue];	// in background thread, just check the queue now for anything to do
		}
	}
}


- (void)sendCommand:(id)command
{
	// Subclasses handle this
}

- (void)setState:(int)aState		// Safe "setter" -- do NOT just change raw variable.  Called by EITHER thread.
{
	KTLog(StateMachineDomain, KTLogDebug, @"Changing State from %@ to %@", [self stateName:_state], [self stateName:aState]);
	
    [super setState:aState];
	
	if ([NSThread currentThread] != _bgThread)
	{
		[self sendPortMessage:COMMAND];		// State has changed, check if we can handle message.
	}
	else
	{
		[self checkQueue];	// in background thread, just check the queue now for anything to do
	}
}

- (void)checkQueue
{
	KTLog(StateMachineDomain, KTLogDebug, @"Checking Queue");
	BOOL nextTry = 0 != [self numberOfCommands];
	while (nextTry)
	{
		ConnectionCommand *command = [[self currentCommand] retain];
		if (GET_STATE == [command awaitState])
		{
			KTLog(StateMachineDomain, KTLogDebug, @"Dispatching Command: %@", [command command]);
			_state = [command sentState];	// don't use setter; we don't want to recurse
			[self pushCommandOnHistoryQueue:command];
			[self dequeueCommand];
			nextTry = (0 != [_commandQueue count]);		// go to next one, there's something else to do
			
			[self sendCommand:[command command]];
		}
		else
		{
			KTLog(StateMachineDomain, KTLogDebug, @"State %@ not ready for command at top of queue: %@, needs %@", [self stateName:GET_STATE], [command command], [self stateName:[command awaitState]]);
			nextTry = NO;		// don't try.  
		}
		[command release];
	}
}	

#pragma mark -
#pragma mark AbstractConnection Overrides

- (void)setDelegate:(id)delegate
{
	[super setDelegate:delegate];
	// Also tell the forwarder to use this delegate.
	[_forwarder setDelegate:delegate];	// note that its delegate it not retained.
}

- (void)openStreamsToPort:(unsigned)port
{
	NSHost *host = [NSHost hostWithName:_connectionHost];
	if(!host){
		KTLog(TransportDomain, KTLogError, @"Cannot find the host: %@", _connectionHost);
		
        if (_flags.error) {
			NSError *error = [NSError errorWithDomain:ConnectionErrorDomain 
												 code:EHOSTUNREACH
											 userInfo:
				[NSDictionary dictionaryWithObjectsAndKeys:LocalizedStringInThisBundle(@"Host Unavailable", @"Couldn't open the port to the host"), NSLocalizedDescriptionKey,
					_connectionHost, @"host", nil]];
            [_forwarder connection:self didReceiveError:error];
		}
		return;
	}
	/* If the host has multiple names it can screw up the order in the list of name */
	if ([[host names] count] > 1) {
#warning Applying KVC hack
		[host setValue:[NSArray arrayWithObject:_connectionHost] forKey:@"names"];
	}
	[self closeStreams];		// make sure streams are closed before opening/allocating new ones
	
	[NSStream getStreamsToHost:host
						  port:port
				   inputStream:&_receiveStream
				  outputStream:&_sendStream];
	
	[_receiveStream retain];	// the above objects are created autorelease; we have to retain them
	[_sendStream retain];
	
	if(!_receiveStream || !_sendStream){
		KTLog(TransportDomain, KTLogError, @"Cannot create a stream to the host: %@", _connectionHost);
		
		if (_flags.error) {
			NSError *error = [NSError errorWithDomain:ConnectionErrorDomain 
												 code:EHOSTUNREACH
											 userInfo:[NSDictionary dictionaryWithObject:LocalizedStringInThisBundle(@"Stream Unavailable", @"Error creating stream")
																				  forKey:NSLocalizedDescriptionKey]];
			[_forwarder connection:self didReceiveError:error];
		}
		return;
	}
}

- (void)connect
{
	// do we really need to do this?
	[self emptyCommandQueue];
	
	int connectionPort = [_connectionPort intValue];
	if (0 == connectionPort)
	{
		connectionPort = 21;	// standard FTP control port
	}
	
	[self openStreamsToPort:connectionPort];
	
	[self sendPortMessage:CONNECT];	// finish the job -- scheduling in the runloop -- in the background thread
}

/*!	Disconnect from host.  Called by foreground thread.
*/
- (void)disconnect
{
	[self sendPortMessage:DISCONNECT];
	[_fileCheckingConnection disconnect];
}

- (void)forceDisconnect
{
	[self sendPortMessage:FORCE_DISCONNECT];
	[_fileCheckingConnection forceDisconnect];
}

#pragma mark -
#pragma mark Stream Delegate Methods

- (void)recalcUploadSpeedWithBytesSent:(unsigned)length
{
	NSDate *now = [NSDate date];
	NSTimeInterval diff = [_lastChunkSent timeIntervalSinceDate:now];
	_uploadSpeed = length / diff;
	[_lastChunkSent autorelease];
	_lastChunkSent = [now retain];
}

- (void)recalcDownloadSpeedWithBytesSent:(unsigned)length
{
	NSDate *now = [NSDate date];
	NSTimeInterval diff = [_lastChunkReceived timeIntervalSinceDate:now];
	_downloadSpeed = length / diff;
	[_lastChunkReceived autorelease];
	_lastChunkReceived = [now retain];
}

- (void)closeStreams
{
	[_receiveStream close];
	[_sendStream close];
	[_receiveStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
	[_sendStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
	[_receiveStream release];
	[_sendStream release];
	_receiveStream = nil;
	_sendStream = nil;
	[_sendBuffer setLength:0];
}

- (void)processReceivedData:(NSData *)data
{
	// we do nothing. subclass has to do the work.
}

- (NSData *)availableData
{
	uint8_t *buf = (uint8_t *)malloc(sizeof(uint8_t) * kStreamChunkSize);
	int len = [_receiveStream read:buf maxLength:kStreamChunkSize];
	NSData *data = nil;
	
	if (len >= 0)
	{
		data = [NSData dataWithBytesNoCopy:buf length:len freeWhenDone:YES];
	}
	
	return data;
}

- (void)sendData:(NSData *)data
{
	[_sendBufferLock lock];
	BOOL bufferEmpty = [_sendBuffer length] == 0;
	[_sendBuffer appendData:data];
	[_sendBufferLock unlock];
		
	if (bufferEmpty) {
		// prime the sending
		[_sendBufferLock lock];
		unsigned chunkLength = MIN(kStreamChunkSize, [_sendBuffer length]);
		NSData *chunk = [_sendBuffer subdataWithRange:NSMakeRange(0,chunkLength)];
		KTLog(StreamDomain, KTLogDebug, @"<< %@", [chunk descriptionAsString]);
		[_sendBuffer replaceBytesInRange:NSMakeRange(0,chunkLength)
							   withBytes:NULL
								  length:0];
		[_sendBufferLock unlock];
		uint8_t *bytes = (uint8_t *)[chunk bytes];
		[_lastChunkSent autorelease];
		_lastChunkSent = [[NSDate date] retain];
		[_sendStream write:bytes maxLength:chunkLength];
		[self stream:_sendStream sentBytesOfLength:chunkLength];
	}
}

- (void)handleReceiveStreamEvent:(NSStreamEvent)theEvent
{
	switch (theEvent)
	{
		case NSStreamEventHasBytesAvailable:
		{
			uint8_t *buf = (uint8_t *)malloc(sizeof(uint8_t) * kStreamChunkSize);
			int len = [_receiveStream read:buf maxLength:kStreamChunkSize];
			if (len >= 0)
			{
				NSData *data = [NSData dataWithBytesNoCopy:buf length:len freeWhenDone:NO];
				KTLog(StreamDomain, KTLogDebug, @"%d >> %@", len, [data descriptionAsString]);
				[self stream:_receiveStream readBytesOfLength:len];
				[self recalcDownloadSpeedWithBytesSent:len];
				[self processReceivedData:data];
			}
			free(buf);
			break;
		}
		case NSStreamEventOpenCompleted:
		{
			KTLog(StreamDomain, KTLogDebug, @"Command receive stream opened");
			break;
		}
		case NSStreamEventErrorOccurred:
		{
			KTLog(StreamDomain, KTLogError, @"receive stream error: %@", [_receiveStream streamError]);
			if (_flags.error) 
			{
				NSError *error = nil;
				
				if (GET_STATE == ConnectionNotConnectedState) {
					error = [NSError errorWithDomain:ConnectionErrorDomain
												code:ConnectionStreamError
											userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"%@ %@?", LocalizedStringInThisBundle(@"Is the service running on the server", @"Stream Error before opening"), [self host]]
																				 forKey:NSLocalizedDescriptionKey]];
				}
				else {
					// we want to catch the connection reset by peer error
					error = [_receiveStream streamError];
					if ([[error domain] isEqualToString:NSPOSIXErrorDomain] && [error code] == ECONNRESET)
					{
						KTLog(TransportDomain, KTLogInfo, @"Connection was reset by peer, attempting to reconnect.", [_receiveStream streamError]);
						error = nil;
						
						// resetup connection again
						[self closeStreams];
						[self setState:ConnectionNotConnectedState];
						// roll back to the first command in this chain of commands
						NSArray *cmds = [[self lastCommand] sequencedChain];
						NSEnumerator *e = [cmds reverseObjectEnumerator];
						ConnectionCommand *cur;
						
						while (cur = [e nextObject])
						{
							[self pushCommandOnCommandQueue:cur];
						}
						
						NSInvocation *inv = [NSInvocation invocationWithSelector:@selector(openStreamsToPort:)
																		  target:self
																	   arguments:[NSArray array]];
						int port = [[self port] intValue];
						[inv setArgument:&port atIndex:2];
						[inv performSelector:@selector(invoke) inThread:_createdThread];
						
						while (_sendStream == nil || _receiveStream == nil)
						{
							[NSThread sleepUntilDate:[NSDate distantPast]];
						}
						
						[self scheduleStreamsOnRunLoop];
						break;
					}
				}
				
				[_forwarder connection:self didReceiveError:error];
			}
			break;
		}
		case NSStreamEventEndEncountered:
		{
			KTLog(StreamDomain, KTLogDebug, @"Command receive stream ended");
			[self closeStreams];
			[self setState:ConnectionNotConnectedState];
			if (_flags.didDisconnect) {
				[_forwarder connection:self didDisconnectFromHost:_connectionHost];
			}
			break;
		}
		case NSStreamEventNone:
		{
			break;
		}
		case NSStreamEventHasSpaceAvailable:
		{
			break;
		}
	}
}

- (void)handleSendStreamEvent:(NSStreamEvent)theEvent
{
	switch (theEvent)
	{
		case NSStreamEventHasBytesAvailable:
		{
			// This can be called in here when send and receive stream are the same.
			uint8_t *buf = (uint8_t *)malloc(sizeof(uint8_t) * kStreamChunkSize);
			int len = [_receiveStream read:buf maxLength:kStreamChunkSize];
			if (len >= 0)
			{
				NSData *data = [NSData dataWithBytesNoCopy:buf length:len freeWhenDone:NO];
				KTLog(StreamDomain, KTLogDebug, @">> %@", [data descriptionAsString]);
				[self recalcDownloadSpeedWithBytesSent:len];
				[self stream:_receiveStream readBytesOfLength:len];
				[self processReceivedData:data];
			}
			free(buf);
			break;
		}
		case NSStreamEventOpenCompleted:
		{
			KTLog(StreamDomain, KTLogDebug, @"Command send stream opened");
		//	if ([(NSInputStream *)_receiveStream hasBytesAvailable]) {
		//		[self stream:_receiveStream handleEvent:NSStreamEventHasBytesAvailable];
		//	}
			break;
		}
		case NSStreamEventErrorOccurred:
		{
			KTLog(StreamDomain, KTLogError, @"send stream error: %@", [_receiveStream streamError]);
			if (_flags.error) 
			{
				NSError *error = nil;
				
				if (GET_STATE == ConnectionNotConnectedState) {
					error = [NSError errorWithDomain:ConnectionErrorDomain
												code:ConnectionStreamError
											userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"%@ %@?", LocalizedStringInThisBundle(@"Is the service running on the server", @"Stream Error before opening"), [self host]]
																				 forKey:NSLocalizedDescriptionKey]];
				}
				else {
					// we want to catch the connection reset by peer error
					error = [_sendStream streamError];
					if ([[error domain] isEqualToString:NSPOSIXErrorDomain] && [error code] == ECONNRESET)
					{
						KTLog(TransportDomain, KTLogInfo, @"Connection was reset by peer, attempting to reconnect.", [_sendStream streamError]);
						error = nil;
						
						// resetup connection again
						[self closeStreams];
						[self setState:ConnectionNotConnectedState];
						
						// roll back to the first command in this chain of commands
						NSArray *cmds = [[self lastCommand] sequencedChain];
						NSEnumerator *e = [cmds reverseObjectEnumerator];
						ConnectionCommand *cur;
						
						while (cur = [e nextObject])
						{
							[self pushCommandOnCommandQueue:cur];
						}
						
						NSInvocation *inv = [NSInvocation invocationWithSelector:@selector(openStreamsToPort:)
																		  target:self
																	   arguments:[NSArray array]];
						int port = [[self port] intValue];
						[inv setArgument:&port atIndex:2];
						[inv performSelector:@selector(invoke) inThread:_createdThread];
						
						while (_sendStream == nil || _receiveStream == nil)
						{
							[NSThread sleepUntilDate:[NSDate distantPast]];
						}
						
						[self scheduleStreamsOnRunLoop];
						break;
					}
				}
				[_forwarder connection:self didReceiveError:error];
			}
			break;
		}
		case NSStreamEventEndEncountered:
		{
			KTLog(StreamDomain, KTLogDebug, @"Command send stream ended");
			[self closeStreams];
			[self setState:ConnectionNotConnectedState];
			if (_flags.didDisconnect) {
				[_forwarder connection:self didDisconnectFromHost:_connectionHost];
			}
			break;
		}
		case NSStreamEventNone:
		{
			break;
		}
		case NSStreamEventHasSpaceAvailable:
		{
			[_sendBufferLock lock];
			unsigned chunkLength = MIN(kStreamChunkSize, [_sendBuffer length]);
			if (chunkLength > 0) {
				uint8_t *bytes = (uint8_t *)[_sendBuffer bytes];
				KTLog(StreamDomain, KTLogDebug, @"<< %s", bytes);
				[(NSOutputStream *)_sendStream write:bytes maxLength:chunkLength];
				[self recalcUploadSpeedWithBytesSent:chunkLength];
				[self stream:_sendStream sentBytesOfLength:chunkLength];
				[_sendBuffer replaceBytesInRange:NSMakeRange(0,chunkLength)
									   withBytes:NULL
										  length:0];
			}
			[_sendBufferLock unlock];
			[self stream:_sendStream sentBytesOfLength:chunkLength];
			break;
		}
		default:
		{
			KTLog(StreamDomain, KTLogError, @"Composite Event Code!  Need to deal with this!");
			break;
		}
	}
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)theEvent
{
	if (stream == (NSStream *)_sendStream) {
		[self handleSendStreamEvent:theEvent];
	} else if (stream == (NSStream *)_receiveStream) {
		[self handleReceiveStreamEvent:theEvent];
	} else {
		KTLog(StreamDomain, KTLogError, @"StreamBasedConnection: unknown stream (%@)", stream);
	}
}

- (void)stream:(id<OutputStream>)stream sentBytesOfLength:(unsigned)length
{
	// we do nothing - just allow subclasses to know that something was sent
}

- (void)stream:(id<InputStream>)stream readBytesOfLength:(unsigned)length
{
	// we do nothing - just allow subclasses to know that something was read
}

#pragma mark -
#pragma mark File Checking

- (void)processFileCheckingQueue
{
	if (!_fileCheckingConnection) {
		_fileCheckingConnection = [[[self class] alloc] initWithHost:[self host]
																port:[self port]
															username:[self username]
															password:[self password]
															   error:nil];
		[_fileCheckingConnection setDelegate:self];
		[_fileCheckingConnection setTranscript:[self propertyForKey:@"FileCheckingTranscript"]];
		[_fileCheckingConnection connect];
	}
	if (!_fileCheckInFlight && [self numberOfFileChecks] > 0)
	{
		_fileCheckInFlight = [[self currentFileCheck] copy];
		NSString *dir = [_fileCheckInFlight stringByDeletingLastPathComponent];
		if (!dir)
			NSLog(@"%@", _fileCheckInFlight);
		[_fileCheckingConnection changeToDirectory:dir];
		[_fileCheckingConnection directoryContents];
	}
}

- (void)checkExistenceOfPath:(NSString *)path
{
	NSString *dir = [path stringByDeletingLastPathComponent];
  
  //if we pass in a relative path (such as xxx.tif), then the last path is @"", with a length of 0, so we need to add the current directory
  //according to docs, passing "/" to stringByDeletingLastPathComponent will return "/", conserving a 1 size
  //
	if (!dir || [dir length] == 0)
	{
		path = [[self currentDirectory] stringByAppendingPathComponent:path];
	}
		
	[self queueFileCheck:path];
	if ([NSThread currentThread] != _bgThread)
	{
		[self sendPortMessage:CHECK_FILE_QUEUE];
	}
	else
	{
		[self processFileCheckingQueue];
	}
	
}

- (void)connection:(id <AbstractConnectionProtocol>)con didReceiveContents:(NSArray *)contents ofDirectory:(NSString *)dirPath;
{
	if (_flags.fileCheck) {
		NSString *name = [_fileCheckInFlight lastPathComponent];
		NSEnumerator *e = [contents objectEnumerator];
		NSDictionary *cur;
		BOOL foundFile = NO;
		
		while (cur = [e nextObject]) 
		{
			if ([[cur objectForKey:cxFilenameKey] isEqualToString:name]) 
			{
				[_forwarder connection:self checkedExistenceOfPath:_fileCheckInFlight pathExists:YES];
				foundFile = YES;
				break;
			}
		}
		if (!foundFile)
		{
			[_forwarder connection:self checkedExistenceOfPath:_fileCheckInFlight pathExists:NO];
		}
	}
	[self dequeueFileCheck];
	[_fileCheckInFlight autorelease];
	_fileCheckInFlight = nil;
	[self performSelector:@selector(processFileCheckingQueue) withObject:nil afterDelay:0.0];
}
@end
