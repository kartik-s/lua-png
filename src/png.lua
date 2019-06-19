local png = {}

local floor = math.floor
local ceil = math.ceil
local min = math.min
local max = math.max
local abs = math.abs

-- utility functions

function memoize(f)
    local cache = {}
    return function(...)
        local key = table.concat({...}, "-")
        if not cache[key] then
            cache[key] = f(...)
        end
        return cache[key]
    end
end

function int(bytes)
    local n = 0
    for i = 1, #bytes do
        n = 256*n + bytes:sub(i, i):byte()
    end
    return n
end
int = memoize(int)

function bint(bits)
    return tonumber(bits, 2) or 0
end
bint = memoize(bint)

function bits(b, width)
    local s = ""
    if type(b) == "number" then
        for i = 1, width do
            s = b%2 .. s
            b = floor(b/2)
        end
    else
        for i = 1, #b do
            s = s .. bits(b:sub(i, i):byte(), 8):reverse()
        end
    end
    return s
end
bits = memoize(bits)

function fill(bytes, len)
    return bytes:rep(floor(len / #bytes)) .. bytes:sub(1, len % #bytes)
end

function zip(t1, t2)
    local zipped = {}
    for i = 1, max(#t1, #t2) do
        zipped[#zipped + 1] = {t1[i], t2[i]}
    end
    return zipped
end

function unzip(zipped)
    local t1, t2 = {}, {}
    for i = 1, #zipped do
        t1[#t1 + 1] = zipped[i][1]
        t2[#t2 + 1] = zipped[i][2]
    end
    return t1, t2
end

function map(f, t)
    local mapped = {}
    for i = 1, #t do
        mapped[#mapped + 1] = f(t[i], i)
    end
    return mapped
end

function filter(pred, t)
    local filtered = {}
    for i = 1, #t do
        if pred(t[i], i) then
            filtered[#filtered + 1] = t[i]
        end
    end
    return filtered
end

function find(key, t)
    if type(key) == "function" then
        for i = 1, #t do
            if key(t[i]) then
                return i
            end
        end
        return nil
    else
        return find(function(x) return x == key end, t)
    end
end

function slice(t, i, j, step)
    local sliced = {}
    for k = i < 1 and 1 or i, i < 1 and #t + i or j or #t, step or 1 do
        sliced[#sliced + 1] = t[k]
    end
    return sliced
end

function range(i, j)
    local r = {}
    for k = j and i or 0, j or i - 1 do
        r[#r + 1] = k
    end
    return r
end

-- streams

function byte_stream(raw)
    local stream = {}    
    local curr = 0
    
    function stream:read(n)
        local b = raw:sub(curr + 1, curr + n)
        curr = curr + n
        return b
    end
    
    function stream:seek(n, whence)
        if n == "beg" then
            curr = 0
        elseif n == "end" then
            curr = #raw
        elseif whence == "beg" then
            curr = n
        else
            curr = curr + n
        end
        return self
    end
    
    function stream:is_empty()
        return curr >= #raw
    end
    
    function stream:pos()
        return curr
    end
    
    function stream:raw()
        return raw
    end
    
    return stream
end

function bit_stream(raw, offset)
    local stream = {}
    local curr = 0
    offset = offset or 0
    
    function stream:read(n, reverse)
        local start = floor(curr/8) + offset + 1
        local b = bits(raw:sub(start, start + ceil(n/8))):sub(curr%8 + 1, curr%8 + n)
        curr = curr + n
        return reverse and b or b:reverse()
    end
    
    function stream:seek(n)
        if n == "beg" then
            curr = 0
        elseif n == "end" then
            curr = #raw
        else
            curr = curr + n
        end
        return self
    end
    
    function stream:is_empty()
        return curr >= 8*#raw
    end
    
    function stream:pos()
        return curr
    end
    
    return stream
end

function output_stream()
    local stream, buffer = {}, {}
    local curr = 0
    
    function stream:write(bytes)
        for i = 1, #bytes do
            buffer[#buffer + 1] = bytes:sub(i, i)
        end
        curr = curr + #bytes
    end
    
    function stream:back_read(offset, n)
        local read = {}
        for i = curr - offset + 1, curr - offset + n do
            read[#read + 1] = buffer[i]
        end
        return table.concat(read)
    end
    
    function stream:back_copy(dist, len)
        local start, copied = curr - dist + 1, {}
        for i = start, min(start + len, curr) do
            copied[#copied + 1] = buffer[i]
        end
        self:write(fill(table.concat(copied), len))
    end
    
    function stream:pos()
        return curr
    end
    
    function stream:raw()
        return table.concat(buffer)
    end
    
    return stream
end

-- inflate

local CL_LENS_ORDER = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}
local MAX_BITS = 15
local PT_WIDTH = 8

function cl_code_lens(stream, hclen)
    local code_lens = {}
    for i = 1, hclen do
        code_lens[#code_lens + 1] = bint(stream:read(3))
    end
    return code_lens
end

function code_tree(lens, alphabet)
    alphabet = alphabet or range(#lens)
    local using = filter(function(x, i) return lens[i] and lens[i] > 0 end, alphabet)
    lens = filter(function(x) return x > 0 end, lens)
    local tree = zip(lens, using)
    table.sort(tree, function(a, b)
        if a[1] == b[1] then
            return a[2] < b[2]
        else
            return a[1] < b[1]
        end
    end)
    return unzip(tree)
end

function codes(lens)
    local codes = {}
    local code = 0
    for i = 1, #lens do
        codes[#codes + 1] = bits(code, lens[i])
        if i < #lens then
            code = (code + 1)*2^(lens[i + 1] - lens[i])
        end
    end
    return codes
end

function handle_long_codes(codes, alphabet, pt)
    local i = find(function(x) return #x > PT_WIDTH end, codes)
    local long = slice(zip(codes, alphabet), i)
    i = 0
    repeat
        local prefix = long[i + 1][1]:sub(1, PT_WIDTH)
        local same = filter(function(x) return x[1]:sub(1, PT_WIDTH) == prefix end, long)
        same = map(function(x) return {x[1]:sub(PT_WIDTH + 1), x[2]} end, same)
        pt[prefix] = {rest = prefix_table(unzip(same)), unused = 0}
        i = i + #same
    until i == #long
end

function prefix_table(codes, alphabet)
    local pt = {}
    if #codes[#codes] > PT_WIDTH then
        handle_long_codes(codes, alphabet, pt)
    end
    for i = 1, #codes do
        local code = codes[i]
        if #code > PT_WIDTH then
            break
        end
        local entry = {value = alphabet[i], unused = PT_WIDTH - #code}
        if entry.unused == 0 then
            pt[code] = entry
        else
            for i = 0, 2^entry.unused - 1 do
                pt[code .. bits(i, entry.unused)] = entry
            end
        end
    end
    return pt
end

function huffman_decoder(lens, alphabet)
    local base_codes = prefix_table(codes(lens), alphabet)
    return function(stream)
        local codes = base_codes
        local entry
        repeat
            entry = codes[stream:read(PT_WIDTH, true)]
            stream:seek(-entry.unused)
            codes = entry.rest
        until not codes
        return entry.value
    end
end

function code_lens(stream, decode, n)
    local lens = {}
    repeat
        local value = decode(stream)
        if value < 16 then
            lens[#lens + 1] = value
        elseif value == 16 then
            for i = 1, bint(stream:read(2)) + 3 do
                lens[#lens + 1] = lens[#lens]
            end
        elseif value == 17 then
            for i = 1, bint(stream:read(3)) + 3 do
                lens[#lens + 1] = 0
            end
        elseif value == 18 then
            for i = 1, bint(stream:read(7)) + 11 do
                lens[#lens + 1] = 0
            end
        end
    until #lens == n
    return lens
end

function code_trees(stream)
    local hlit = bint(stream:read(5)) + 257
    local hdist = bint(stream:read(5)) + 1
    local hclen = bint(stream:read(4)) + 4
    local cl_decode = huffman_decoder(code_tree(cl_code_lens(stream, hclen), CL_LENS_ORDER))
    local ll_decode = huffman_decoder(code_tree(code_lens(stream, cl_decode, hlit)))
    local d_decode = huffman_decoder(code_tree(code_lens(stream, cl_decode, hdist)))
    return ll_decode, d_decode
end

function extra_bits(value)
    if value >= 4 and value <= 29 then
        return floor(value/2) - 1
    elseif value >= 265 and value <= 284 then
        return ceil(value/4) - 66
    else
        return 0
    end
end
extra_bits = memoize(extra_bits)

function decode_len(value, bits)
    assert(value >= 257 and value <= 285, "value out of range")
    assert(#bits == extra_bits(value), "wrong number of extra bits")
    if value <= 264 then
        return value - 254
    elseif value == 285 then
        return 258
    end
    local len = 11
    for i = 1, #bits - 1 do
        len = len + 2^(i+2)
    end
    return floor(bint(bits) + len + ((value - 1) % 4)*2^#bits)
end
decode_len = memoize(decode_len)

function a(n)
    if n <= 3 then
        return n + 2
    else
        return a(n-1) + 2*a(n-2) - 2*a(n-3)
    end
end
a = memoize(a)

function decode_dist(value, bits)
    assert(value >= 0 and value <= 29, "value out of range")
    assert(#bits == extra_bits(value), "wrong number of extra bits")
    return bint(bits) + a(value - 1)
end
decode_dist = memoize(decode_dist)

function inflate(stream)
    local ostream = output_stream()
    repeat
        local bfinal, btype = bint(stream:read(1)), bint(stream:read(2))
        assert(btype == 2, "compression method not supported")
        local ll_decode, d_decode = code_trees(stream)
        while true do
            local value = ll_decode(stream)
            if value < 256 then
                ostream:write(string.char(value))
            elseif value == 256 then
                break
            else
                local len = decode_len(value, stream:read(extra_bits(value)))
                value = d_decode(stream)
                local dist = decode_dist(value, stream:read(extra_bits(value)))
                ostream:back_copy(dist, len)
            end
        end
    until bfinal == 1
    return ostream:raw()
end

-- chunk processing

local CHANNELS = {}
CHANNELS[0] = 1
CHANNELS[2] = 3
CHANNELS[4] = 2
CHANNELS[6] = 4
 
function process_header(stream, image)
    stream:seek(8)
    image.width = int(stream:read(4))
    image.height = int(stream:read(4))
    image.bit_depth = int(stream:read(1))
    image.color_type= int(stream:read(1))
    image.channels = CHANNELS[image.color_type]
    image.compression_method = int(stream:read(1))
    image.filter_method = int(stream:read(1))
    image.interlace_method = int(stream:read(1))
    assert(image.interlace_method == 0, "interlacing not supported")
    stream:seek(4)
end

function process_data(stream, image)
    local chunk_len = int(stream:read(4))
    stream:seek(4)
    assert(int(stream:read(2)) % 31 == 0, "invalid zlib header")
    stream:seek(-2)
    local dstream = output_stream()
    repeat
        dstream:write(stream:read(chunk_len))
        stream:seek(4)
        chunk_len = int(stream:read(4))
    until stream:read(4) ~= "IDAT"
    stream:seek(-8)
    local bstream = bit_stream(dstream:raw(), 2)
    image.data = inflate(bstream)
end

function process_chunk(stream, image)
    local chunk_len = int(stream:read(4))
    local chunk_type = stream:read(4)
    stream:seek(-8)
    if chunk_type == "IHDR" then
        process_header(stream, image)
    elseif chunk_type == "IDAT" then
        process_data(stream, image)
    elseif chunk_type == "IEND" then
        stream:seek("end")
    else
        stream:seek(chunk_len + 12)
    end
end

-- reconstruction

function paeth(a, b, c)
    local p = a + b - c
    local pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc then
        return a
    elseif pb <= pc then
        return b
    else
        return c
    end
end

function scanlines(image)
    assert(image.bit_depth % 8 == 0, "bit depth not supported")
    local stream = byte_stream(image.data)
    local pixel_width = image.channels * image.bit_depth/8
    local scanline_width = image.width * pixel_width
    local ostream = output_stream()
    return function()
        local lstream = output_stream()
        if not stream:is_empty() then
            local filter_method = int(stream:read(1))
            for i = 1, scanline_width do
                local x = int(stream:read(1))
                local a = int(ostream:back_read(pixel_width, 1))
                local b = int(ostream:back_read(scanline_width, 1))
                local c = int(ostream:back_read(scanline_width + pixel_width, 1))
                if i <= pixel_width then
                    a, c = 0, 0
                end
                local byte
                if filter_method == 0 then
                    byte = string.char(x)
                elseif filter_method == 1 then
                    byte = string.char((x + a)  % 256)
                elseif filter_method == 2 then
                    byte = string.char((x + b) % 256)
                elseif filter_method == 3 then
                    byte = string.char((x + floor((a + b)/2)) % 256)
                elseif filter_method == 4 then
                    byte = string.char((x + paeth(a, b, c)) % 256)
                end
                lstream:write(byte)
                ostream:write(byte)
            end
        end
        return lstream:raw()
    end
end

function pixel(stream, color_type, bit_depth)
    assert(bit_depth % 8 == 0, "bit depth not supported")
    local channels = CHANNELS[color_type]
    local function read_value()
        return int(stream:read(bit_depth/8))/2^bit_depth
    end
    if color_type == 0 then
        return {
            v = read_value()
        }
    elseif color_type == 2 then
        return {
            r = read_value(),
            g = read_value(),
            b = read_value()
        }
    elseif color_type == 4 then
        return {
            v = read_value(),
            a = read_value()
        }
    elseif color_type == 6 then
        return {
            r = read_value(),
            g = read_value(),
            b = read_value(),
            a = read_value()
        }
    end
end

function png.pixels(image)
    local i = 0
    local next_scanline = scanlines(image)
    local scanline = byte_stream(next_scanline())
    return function()
        if scanline:is_empty() then
            return
        end
        local p = pixel(scanline, image.color_type, image.bit_depth)
        local x = i % image.width
        local y = floor(i / image.width)
        i = i + 1
        if scanline:is_empty() then
            scanline = byte_stream(next_scanline())
        end
        return p, x, y
    end
end

-- exports

local PNG_HEADER = string.char(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)

function png.load_from_file(filename)
    local file = io.open(filename, "rb")
    local data = file:read("*all")
    file:close()
    return png.load(data)
end

function png.load(data)
    local stream = byte_stream(data)
    assert(stream:read(8) == PNG_HEADER, "PNG header not found")
    local image = {}
    repeat
        process_chunk(stream, image)
    until stream:is_empty()
    return image
end

return png

