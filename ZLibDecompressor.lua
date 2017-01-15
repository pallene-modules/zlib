--[[
This file is part of zlib. It is subject to the licence terms in the COPYRIGHT file found in the top-level directory of this distribution and at https://raw.githubusercontent.com/pallene-modules/zlib/master/COPYRIGHT. No part of zlib, including this file, may be copied, modified, propagated, or distributed except according to the terms contained in the COPYRIGHT file.
Copyright © 2015 The developers of zlib. See the COPYRIGHT file in the top-level directory of this distribution and at https://raw.githubusercontent.com/pallene-modules/zlib/master/COPYRIGHT.
]]--


local halimede = require('halimede')
local zlib = require('zlib')
local ffi = require('ffi')
local libz = ffi.load('z')
local zlib_h = zlib.h
local assert = halimede.assert
local exception = halimede.exception


local ZLibDecompressor = halimede.moduleclass('ZLibDecompressor')

local GzipOnlyWindowBits = tonumber(libz.Z_MAX_WBITS) + 16

local function version()
	return ffi.string(libz.zlibVersion())
end

module.static.OptimumDeflateBufferSize = 16384  -- 16Kb

module.static.initialiseGzipOnlyDeflation = function(outputUserCallback, bufferSize)
	assert.parameterTypeIsNumber('bufferSize', bufferSize)
	
	return ZLibDecompressor:new(outputUserCallback, bufferSize, GzipOnlyWindowBits)
end

function module:initialize(outputUserCallback, bufferSize, windowBits)
	assert.parameterTypeIsNumber('bufferSize', bufferSize)
	assert.parameterTypeIsNumber('windowBits', windowBits)
	
	if bufferSize < 256 then
		exception.throw('bufferSize \'%s\' is too small; we need at least 256 bytes', bufferSize)
	end

	local zStream = ffi.new('z_stream')
	local resultCode = libz.inflateInit2_(zStream, windowBits, version(), ffi.sizeof(zStream))
	if resultCode ~= tonumber(libz.Z_OK) then
		exception.throw(('Could not initialise gzip inflate; zlib result code was \'%s\' (%s)'):format(tonumber(resultCode), ffi.string(libz.zError(resultCode))))
	end
	ffi.gc(zStream, libz.inflateEnd)
	
	local outputBufferSize = bufferSize
	local outputBuffer = ffi.new('uint8_t[?]', outputBufferSize)
		
	zStream.next_out = outputBuffer
	zStream.avail_out = outputBufferSize
	zStream.next_in = nil
	zStream.avail_in = 0
	
	self.outputUserCallback = outputUserCallback
	self.outputBufferSize = outputBufferSize
	self.outputBuffer = outputBuffer
	self.residualInputAvailable = 0
	self.zStream = zStream
	self.ended = false
end

function module:_callOutputUserCallback(finished)
	self.outputUserCallback(self.outputBuffer, self.outputBufferSize - self.zStream.avail_out, finished)
	self.zStream.next_out = self.outputBuffer
	self.zStream.avail_out = self.outputBufferSize
end

function module:inflate(ffiBufferPointer, numberOfBytes)
	if numberOfBytes == 0 then
		return false
	end
	
	if self.ended then
		exception.throw('Data after end of stream')
	end
	
	self.zStream.next_in = ffiBufferPointer
	self.zStream.avail_in = numberOfBytes
	
	repeat
		local resultCode = libz.inflate(self.zStream, libz.Z_NO_FLUSH)
		
		if resultCode == tonumber(libz.Z_STREAM_END) then
			self:_callOutputUserCallback(true)
			self.ended = true
			self.zStream.next_in = nil
			return true
		elseif resultCode == tonumber(libz.Z_OK) then
			if self.zStream.avail_out == 0 then
				self:_callOutputUserCallback(false)
			end
		elseif resultCode == tonumber(libz.Z_BUF_ERROR) then
			-- Need to clear space in output buffer
			self:_callOutputUserCallback(false)
			
			-- avail_in may be zero but it's possible there's data moved from next_in into zStream's internal data buffer (sliding window)
		else
			exception.throw('Bad data')
		end
	until self.zStream.avail_in == 0
	
	self.zStream.next_in = nil
end

function module:finish()
	if self.ended then
		return
	end
	
	if self.zStream.avail_out ~= self.outputBufferSize then
		self:_callOutputUserCallback(false)
	end
	
	self.zStream.avail_in = 0
	
	repeat
		local resultCode = libz.inflate(self.zStream, libz.Z_NO_FLUSH)
		
		if resultCode == tonumber(libz.Z_STREAM_END) then
			self:_callOutputUserCallback(true)
			break
		elseif resultCode == tonumber(libz.Z_OK) then
			if self.zStream.avail_out == 0 then
				self:_callOutputUserCallback(false)
			end
		elseif resultCode == tonumber(libz.Z_BUF_ERROR) then
			-- Need to clear space in output buffer
			self:_callOutputUserCallback(false)
		else
			exception.throw('Bad data')
		end
		
	until false
	
	self.ended = true
end
