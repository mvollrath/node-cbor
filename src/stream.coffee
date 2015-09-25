BinaryParseStream = require 'binary-parse-stream'
Tagged = require './tagged'
Simple = require './simple'
BufferStream = require './BufferStream'
utils = require './utils'
bignumber = require 'bignumber.js'

# TODO: check node version, fail nicely

{MT, NUM_BYTES, SIMPLE} = require './constants'

SHIFT_32 = new bignumber(2).pow(32)
NEG_ONE = new bignumber(-1)
MAX_SAFE_BIG = new bignumber(Number.MAX_SAFE_INTEGER.toString(16), 16)
MAX_SAFE_HIGH = 0x1fffff

COUNT = Symbol('count')
PENDING_KEY = Symbol('pending_key')
PARENT = Symbol('parent')
BREAK = Symbol('break')
MAJOR = Symbol('major type')
NULL = Symbol('null')
NOTHING = Symbol('nothing')
ERROR = Symbol('error')
STREAM = Symbol('stream')

parseCBORint = (ai, buf) ->
  switch ai
    when NUM_BYTES.ONE then buf.readUInt8(0, true)
    when NUM_BYTES.TWO then buf.readUInt16BE(0, true)
    when NUM_BYTES.FOUR then buf.readUInt32BE(0, true)
    when NUM_BYTES.EIGHT
      f = buf.readUInt32BE(0)
      g = buf.readUInt32BE(4)
      # 2^53-1 maxint
      if f > MAX_SAFE_HIGH
        # alternately, we could throw an error.
        new bignumber(f).times(SHIFT_32).plus(g)
      else
        (f * SHIFT_32) + g
    else
      throw new Error "Invalid additional info for int: #{ai}"

parseCBORfloat = (buf) ->
  switch buf.length
    when 2 then utils.parseHalf buf
    when 4 then buf.readFloatBE 0, true
    when 8 then buf.readDoubleBE 0, true
    else
      throw new Error "Invalid float size: #{buf.length}"

parentArray = (parent, typ, count) ->
  a         = []
  a[COUNT]  = count
  a[PARENT] = parent
  a[MAJOR]  = typ
  a

parentBufferStream = (parent, typ) ->
  b = new BufferStream
  b[PARENT] = parent
  b[MAJOR] = typ
  b

module.exports = class CborStream extends BinaryParseStream
  @PARENT: PARENT
  @NULL: NULL
  @BREAK: BREAK
  @STREAM: STREAM

  @nullcheck: (val) ->
    if val == NULL
      null
    else
      val

  @decodeFirst: (buf, encoding = 'utf-8', cb) ->
    # stop parsing after the first item  (SECURITY!)
    # error if there are bytes left over
    opts = {}
    switch typeof(encoding)
      when 'function'
        cb = encoding
        encoding = undefined
      when 'object'
        opts = encoding
        encoding = opts.encoding
        delete opts.encoding

    c = new CborStream opts
    p = undefined
    v = NOTHING
    c.on 'data', (val) ->
      v = CborStream.nullcheck val
      c.close()
    if typeof(cb) == 'function'
      c.once 'error', (er) ->
        unless v == ERROR
          v = ERROR
          c.close()
          cb er
      c.once 'end', ->
        switch v
          when NOTHING
            cb new Error 'No CBOR found'
          when ERROR
            undefined
          else
            cb null, v
    else
      p = new Promise (resolve, reject) ->
        c.once 'error', (er) ->
          v = ERROR
          c.close()
          reject er
        c.once 'end', ->
          switch v
            when NOTHING
              reject new Error 'No CBOR found'
            when ERROR
              undefined
            else
              resolve v

    c.end buf, encoding
    p

  @decodeAll: (buf, encoding = 'utf-8', cb) ->
    opts = {}
    switch typeof(encoding)
      when 'function'
        cb = encoding
        encoding = undefined
      when 'object'
        opts = encoding
        encoding = opts.encoding
        delete opts.encoding

    c = new CborStream opts
    p = undefined
    if typeof(cb) == 'function'
      c.on 'data', (val) ->
        cb null, CborStream.nullcheck(val)
      c.on 'error', (er) ->
        cb er
    else
      p = new Promise (resolve, reject) ->
        vals = []
        c.on 'data', (val) ->
          vals.push CborStream.nullcheck(val)
        c.on 'error', (er) ->
          reject er
        c.on 'end', ->
          resolve vals

    c.end buf, encoding
    p

  constructor: (options) ->
    @tags = options?.tags
    delete options?.tags
    @max_depth = options?.max_depth || -1
    delete options?.max_depth
    @running = true
    super options

  close: ->
    @running = false
    @__fresh = true

  _parse: ->
    parent = null
    depth = 0
    while true
      if (@max_depth >= 0) and (depth > @max_depth)
        throw new Error "Maximum depth #{@max_depth} exceeded"

      octet = yield(-1)
      if !@running
        throw new Error "Unexpected data: 0x#{octet.toString(16)}"

      mt = octet >> 5
      ai = octet & 0x1f

      switch ai
        when NUM_BYTES.ONE
          ai = yield(-1)
        when NUM_BYTES.TWO, NUM_BYTES.FOUR, NUM_BYTES.EIGHT
          buf = yield(1 << (ai - 24))
          ai = if mt == MT.SIMPLE_FLOAT
            buf
          else
            parseCBORint(ai, buf)
        when 28, 29, 30
          @running = false
          throw new Error "Additional info not implemented: #{ai}"
        when NUM_BYTES.INDEFINITE
          ai = -1
        # else ai is already correct

      switch mt
        when MT.POS_INT then undefined # do nothing
        when MT.NEG_INT
          if ai == Number.MAX_SAFE_INTEGER
            ai = MAX_SAFE_BIG
          if ai instanceof bignumber
            ai = NEG_ONE.sub ai
          else
            ai = -1 - ai
        when MT.BYTE_STRING, MT.UTF8_STRING
          switch ai
            when 0
              ai = if (mt == MT.BYTE_STRING) then new Buffer(0) else ''
            when -1
              @emit 'start', mt, STREAM, parent?[MAJOR], parent?.length
              parent = parentBufferStream parent, mt
              depth++
              continue
            else
              ai = yield(ai)
              if mt == MT.UTF8_STRING
                ai = ai.toString 'utf-8'
        when MT.ARRAY, MT.MAP
          switch ai
            when 0
              ai = if (mt == MT.MAP) then {} else []
              ai[PARENT] = parent
            when -1
              # streaming
              @emit 'start', mt, STREAM, parent?[MAJOR], parent?.length
              parent = parentArray parent, mt, -1
              depth++
              continue
            else
              @emit 'start', mt, NULL, parent?[MAJOR], parent?.length
              # 1 for Array, 2 for Map
              parent = parentArray parent, mt, ai * (mt - 3)
              depth++
              continue
        when MT.TAG
          @emit 'start', mt, ai, parent?[MAJOR], parent?.length
          parent = parentArray parent, mt, 1
          parent.push ai
          depth++
          continue
        when MT.SIMPLE_FLOAT
          if typeof(ai) == 'number' # simple values
            ai = switch ai
              when SIMPLE.FALSE then false
              when SIMPLE.TRUE then true
              when SIMPLE.NULL
                if parent?
                  null
                else
                  NULL # HACK
              when SIMPLE.UNDEFINED then undefined
              when -1
                if !parent?
                  @running = false
                  throw new Error 'Invalid BREAK'
                parent[COUNT] = 1
                BREAK
              else new Simple(ai)
          else
            ai = parseCBORfloat ai

      @emit 'value', ai, parent?[MAJOR], parent?.length
      again = false
      while parent?
        switch
          when ai == BREAK
            undefined # do nothing
          when Array.isArray(parent)
            parent.push ai
          when parent instanceof BufferStream
            pm = parent[MAJOR]
            if pm? and (pm != mt)
              @running = false
              throw new Error 'Invalid major type in indefinite encoding'
            parent.write ai
          else
            @running = false
            throw new Error 'Unknown parent type'

        if (--parent[COUNT]) != 0
          again = true
          break

        --depth
        delete parent[COUNT]
        @emit 'stop', parent[MAJOR]
        ai = switch
          when Array.isArray parent
            switch parent[MAJOR]
              when MT.ARRAY
                parent
              when MT.MAP
                allstrings = true
                if (parent.length % 2) != 0
                  throw new Error("Invalid map length: #{parent.length}")
                for i in [0...parent.length] by 2
                  if typeof(parent[i]) != 'string'
                    allstrings = false
                    break
                if allstrings
                  a = {}
                  for i in [0...parent.length] by 2
                    a[parent[i]] = parent[i + 1]
                  a
                else
                  a = new Map
                  for i in [0...parent.length] by 2
                    a.set parent[i], parent[i + 1]
                  a
              when MT.TAG
                t = new Tagged parent[0], parent[1]
                t.convert @tags
              else
                throw new Error 'Invalid state'

          when parent instanceof BufferStream
            switch parent[MAJOR]
              when MT.BYTE_STRING
                parent.flatten()
              when MT.UTF8_STRING
                parent.toString('utf-8')
              else
                @running = false
                throw new Error 'Invalid stream major type'
          else
            # can this still happen
            throw new Error 'Invalid state'
            parent

        parent = parent[PARENT]
      if !again
        if depth != 0
          throw new Error 'Depth problem'
        return ai