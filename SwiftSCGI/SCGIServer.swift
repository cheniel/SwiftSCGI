//
//  SCGIServer.swift
//  SwiftSCGI
//
//  Created by Rod Schmidt on 11/21/14.
//  Copyright (c) 2014 infiniteNIL. All rights reserved.
//

import Foundation

public enum SCGIServerState {
	case Idle
	case Starting
	case Running
	case Stopping
}

let SCGI_SERVER_ADDRESS = "127.0.0.1"

struct SCGIRequest {
	var contentLength: Int = 0
	var headers: [String : String] = [:]
	var body: String = ""
}

public let SCGIServerNotificationStateChanged = "SCGIServerNotificationStateChanged"

public class SCGIServer : NSObject {
	let port: in_port_t

	var listeningHandle: NSFileHandle?
	var socket: CFSocketRef?
	var incomingRequests: [NSFileHandle : NSMutableData] = [:]
	var responseHandlers: [SCGIMessageHandler] = []
	var SCGIHeadersContentLength: Int = 0

	init(port: in_port_t) {
		self.port = port
	}

	private(set) var lastError: NSError? {
		didSet {
			if let error = lastError {
				stop()
				state = .Idle
				NSLog("SCGIServer error: %@", error);
			}
		}
	}

	private(set) var state: SCGIServerState = .Idle {
		didSet {
			if state != oldValue {
				NSNotificationCenter.defaultCenter().postNotificationName(SCGIServerNotificationStateChanged, object:self)
			}
		}
	}

	//
	// Creates the socket and starts listening for connections on it.
	//
	func start() {
		lastError = nil;
		state = .Starting

		let serverIPAddress = inet_addr(SCGI_SERVER_ADDRESS)
		if serverIPAddress == __uint32_t.max {
			errorWithName("Unable to parse server address")
			return
		}

		socket = CFSocketCreate(nil, PF_INET, SOCK_STREAM, IPPROTO_TCP, 0, nil, nil)
		if socket == nil {
			errorWithName("Unable to create socket.")
			return
		}

		var reuse = 1;
		let fileDescriptor = CFSocketGetNative(socket!)
		if setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(sizeofValue(reuse))) != 0 {
			errorWithName("Unable to set socket options.")
			return
		}

		var address = sockaddr()
		address.sa_family = sa_family_t(AF_INET)
		address.sin_addr = serverIPAddress
		address.sin_port = port
		let addressData = NSData(bytes: &address, length: sizeof(sockaddr))
		if CFSocketSetAddress(socket!, addressData) != .Success {
			errorWithName("Unable to bind socket to address.")
			return
		}

		listeningHandle = NSFileHandle(fileDescriptor: fileDescriptor, closeOnDealloc:true)

		NSNotificationCenter.defaultCenter()
			.addObserver(self, selector: "receiveIncomingConnectionNotification:",
				name:NSFileHandleConnectionAcceptedNotification, object: nil)

		listeningHandle?.acceptConnectionInBackgroundAndNotify()
		state = .Running
	}

	//
	// Receive the notification for a new incoming request. This method starts
	// receiving data from the incoming request's file handle and creates a
	// new CFHTTPMessageRef to store the incoming data..
	//
	func receiveIncomingConnectionNotification(notification: NSNotification) {
		let userInfo = notification.userInfo!
		let incomingFileHandle = userInfo[NSFileHandleNotificationFileHandleItem] as NSFileHandle?

		if incomingFileHandle != nil {
			incomingRequests[incomingFileHandle!] = NSMutableData()

			NSNotificationCenter.defaultCenter()
				.addObserver(self, selector: "receiveIncomingDataNotification:",
					name: NSFileHandleDataAvailableNotification, object: incomingFileHandle)

			incomingFileHandle?.waitForDataInBackgroundAndNotify()
		}

		listeningHandle?.acceptConnectionInBackgroundAndNotify()
	}

	//
	// Receive new data for an incoming connection.
	//
	// Once enough data is received to fully parse the SCGI message,
	// a SCGIResponseHandler will be spawned to generate a response.
	//
	func receiveIncomingDataNotification(notification: NSNotification) {
		let incomingFileHandle = notification.object as NSFileHandle!
		let incomingData = incomingFileHandle?.availableData

		if incomingData?.length == 0 {
			stopReceivingForFileHandle(incomingFileHandle, closeFileHandle: false)
			return
		}

		let requestData = incomingRequests[incomingFileHandle]
		if requestData == nil {
			stopReceivingForFileHandle(incomingFileHandle, closeFileHandle: true)
			return
		}

		requestData?.appendData(incomingData!)

		if SCGIHeadersContentLength == 0 {
			// We need to parse the data and figure out what the content length is
			if let length = SCGIHeadersLength(incomingData!) {
				SCGIHeadersContentLength = length
			}
			else {
				stopReceivingForFileHandle(incomingFileHandle, closeFileHandle: true)
				return
			}
		}

		if (requestData?.length >= SCGIHeadersContentLength) {
			// We've received all the data
			let handler = SCGIMessageHandler(message: SCGIMessage(data: requestData!),
				requestFileHandle: incomingFileHandle, server: self)
			responseHandlers.append(handler);
			stopReceivingForFileHandle(incomingFileHandle, closeFileHandle: false)
			handler.startResponse()
			return
		}
		else {
			// More data is coming
			incomingFileHandle.waitForDataInBackgroundAndNotify()
		}
	}

	//
	// Shuts down a response handler and removes it from the set of handlers.
	//
	func closeHandler(handler: SCGIMessageHandler) {
		handler.endResponse()
		if let index = find(responseHandlers, handler) {
			responseHandlers.removeAtIndex(index)
		}
	}

	//
	// Stops the server.
	//
	func stop() {
		state = .Stopping

		NSNotificationCenter.defaultCenter()
			.removeObserver(self, name: NSFileHandleConnectionAcceptedNotification, object: nil)

		responseHandlers.removeAll(keepCapacity: false)

		listeningHandle?.closeFile()
		listeningHandle = nil;

		for (incomingFileHandle, _) in incomingRequests	{
			stopReceivingForFileHandle(incomingFileHandle, closeFileHandle: true)
		}

		if socket != nil {
			CFSocketInvalidate(socket);
			socket = nil;
		}

		state = .Idle
	}

	//
	// If a file handle is accumulating the header for a new connection, this
	// method will close the handle, stop listening to it and release the
	// accumulated memory.
	//
	// Parameters:
	//    incomingFileHandle - the file handle for the incoming request
	//    closeFileHandle - if YES, the file handle will be closed, if no it is
	//		assumed that an HTTPResponseHandler will close it when done.
	//
	func stopReceivingForFileHandle(incomingFileHandle: NSFileHandle, closeFileHandle: Bool) {
		if closeFileHandle {
			incomingFileHandle.closeFile()
		}

		NSNotificationCenter.defaultCenter()
			.removeObserver(self, name: NSFileHandleDataAvailableNotification, object: incomingFileHandle)
		incomingRequests.removeValueForKey(incomingFileHandle)
	}

	//
	// Stops the server and sets the last error to "errorName", localized using the
	// HTTPServerErrors.strings file (if present).
	//
	// Parameters:
	//    errorName - the description used for the error
	//
	private func errorWithName(errorName: NSString) {
		let userInfo = [NSLocalizedDescriptionKey: NSLocalizedString(errorName, comment: "")]
		lastError = NSError(domain: "SCGIServerError", code: 0, userInfo: userInfo)
	}

}
