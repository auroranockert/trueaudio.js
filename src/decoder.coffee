class TTADecoder extends Decoder
    Decoder.register('tta', TTADecoder)
    
    FORMAT_SIMPLE = 1
    FORMAT_ENCRYPTED = 2
    MAX_ORDER = 16
    ttafilter_configs = [
        [10, 1]
        [9, 1]
        [10, 1]
        [12, 1]
    ]
    
    shift_1 = new Uint32Array([
        0x00000001, 0x00000002, 0x00000004, 0x00000008
        0x00000010, 0x00000020, 0x00000040, 0x00000080
        0x00000100, 0x00000200, 0x00000400, 0x00000800
        0x00001000, 0x00002000, 0x00004000, 0x00008000
        0x00010000, 0x00020000, 0x00040000, 0x00080000
        0x00100000, 0x00200000, 0x00400000, 0x00800000
        0x01000000, 0x02000000, 0x04000000, 0x08000000
        0x10000000, 0x20000000, 0x40000000, 0x80000000
        0x80000000, 0x80000000, 0x80000000, 0x80000000
        0x80000000, 0x80000000, 0x80000000, 0x80000000
    ])
    
    shift_16 = shift_1.subarray(4)
    
    ttafilter_init = (channel, config) ->
        [shift, mode] = config
        channel.filter = 
            shift: shift
            round: shift_1[shift - 1]
            mode: mode
            qm: new Int32Array(MAX_ORDER)
            dx: new Int32Array(MAX_ORDER)
            dl: new Int32Array(MAX_ORDER)
            
    rice_init = (channel, k0, k1) ->
        channel.rice = 
            k0: k0
            k1: k1
            sum0: shift_16[k0]
            sum1: shift_16[k1]
            
    tta_get_unary = (bitstream) ->
        ret = 0
        
        # count ones
        while bitstream.available(1) and bitstream.readOne()
            ret++
            
        return ret
        
    memshl = (a) ->
        a[i = 0] = a[b = 1]
        a[i++] = a[b++]
        a[i++] = a[b++]
        a[i++] = a[b++]
        a[i++] = a[b++]
        a[i++] = a[b++]
        a[i++] = a[b++]
        a[i++] = a[b++]
       
    ttafilter_process = (c, p) ->
        {dl, qm, dx, round:sum} = c
        dl_i = qm_i = dx_i = 0
        
        if not c.error
            sum += dl[dl_i++] * qm[qm_i++]
            sum += dl[dl_i++] * qm[qm_i++]
            sum += dl[dl_i++] * qm[qm_i++]
            sum += dl[dl_i++] * qm[qm_i++]
            sum += dl[dl_i++] * qm[qm_i++]
            sum += dl[dl_i++] * qm[qm_i++]
            sum += dl[dl_i++] * qm[qm_i++]
            sum += dl[dl_i++] * qm[qm_i++]
            dx += 8
            
        else if c.error < 0
            sum += dl[dl_i++] * (qm[qm_i++] -= dx[dx_i++])
            sum += dl[dl_i++] * (qm[qm_i++] -= dx[dx_i++])
            sum += dl[dl_i++] * (qm[qm_i++] -= dx[dx_i++])
            sum += dl[dl_i++] * (qm[qm_i++] -= dx[dx_i++])
            sum += dl[dl_i++] * (qm[qm_i++] -= dx[dx_i++])
            sum += dl[dl_i++] * (qm[qm_i++] -= dx[dx_i++])
            sum += dl[dl_i++] * (qm[qm_i++] -= dx[dx_i++])
            sum += dl[dl_i++] * (qm[qm_i++] -= dx[dx_i++])
            
        else 
            sum += dl[dl_i++] * (qm[qm_i++] += dx[dx_i++])
            sum += dl[dl_i++] * (qm[qm_i++] += dx[dx_i++])
            sum += dl[dl_i++] * (qm[qm_i++] += dx[dx_i++])
            sum += dl[dl_i++] * (qm[qm_i++] += dx[dx_i++])
            sum += dl[dl_i++] * (qm[qm_i++] += dx[dx_i++])
            sum += dl[dl_i++] * (qm[qm_i++] += dx[dx_i++])
            sum += dl[dl_i++] * (qm[qm_i++] += dx[dx_i++])
            sum += dl[dl_i++] * (qm[qm_i++] += dx[dx_i++])
            
        dx[dx_i - 0] = ((dl[dl_i - 1] >> 30) | 1) << 2
        dx[dx_i - 1] = ((dl[dl_i - 2] >> 30) | 1) << 1
        dx[dx_i - 2] = ((dl[dl_i - 3] >> 30) | 1) << 1
        dx[dx_i - 3] = ((dl[dl_i - 4] >> 30) | 1)
        
        # mode == 0
        c.error = p
        p += (sum >> c.shift)
        dl[dl_i] = p
        
        memshl(dl)
        memshl(dx)
        
        return p
        
    readChunk: =>
        frameLen = 256 * @format.sampleRate / 245
        numChannels = @format.channelsPerFrame
        bps = (@format.bitsPerChannel + 7) / 8 | 0
        stream = @bitstream
        
        unless stream.available(frameLen)
            return @once 'available', @readChunk
        
        decode_buffer = new Int32Array(frameLen * numChannels)
        
        # init per channel states
        channels = []
        for i in [0...numChannels] by 1
            channels[i] = 
                predictor: 0
                
            ttafilter_init(channels[i], ttafilter_configs[bps - 1])
            rice_init(channels[i], 10, 10)                    
        
        cur_chan = 0
        for p in [0...frameLen * numChannels] by 1
            {predictor, filter, rice} = channels[cur_chan]
            
            unary = tta_get_unary(stream)
            
            if unary is 0
                depth = 0
                k = rice.k0
            else
                depth = 1
                k = rice.k1
                unary--
                
            return -1 unless stream.available(k)
            
            if k
                value = (unary << k) + stream.read(k)
            else
                value = unary
                
            switch depth
                when 1
                    rice.sum1 += value - (rice.sum1 >>> 4)
                    
                    if rice.k1 > 0 and rice.sum1 < shift_16[rice.k1]
                        rice.k1--
                    else if rice.sum1 > shift_16[rice.k1 + 1]
                        rice.k1++
                        
                    value += shift_1[rice.k0]
                    
                else
                    rice.sum0 += value - (rice.sum0 >>> 4)
                    
                    if rice.k0 > 0 && rice.sum0 < shift_16[rice.k0]
                        rice.k0--
                    else if rice.sum0 > shift_16[rice.k0 + 1]
                        rice.k0++
                        
            # extract coded value
            decode_buffer[p] = if value & 1 then ++value >> 1 else -value >> 1
            
            # run hybrid filter
            decode_buffer[p] = ttafilter_process(filter, decode_buffer[p])
            
            # fixed order prediction
            switch bps
                when 1
                    p += ((predictor << 4) - predictor) >> k
                when 2, 3
                    p += ((predictor << 5) - predictor) >> k
                when 4
                    p += predictor
                    
            channels[cur_chan].predictor = decode_buffer[p]
            
            # flip channels
            if cur_chan < numChannels - 1
                cur_chan++
            else
                # decorrelate in case of stereo integer
                if numChannels > 1
                    r = p - 1
                    decode_buffer[p] += decode_buffer[r] / 2
                    while r > p - numChannels
                        decode_buffer[r] = decode_buffer[r + 1] - decode_buffer[r]
                    
                console.log 'hi'
                cur_chan = 0
                
        stream.advance(32) # skip frame crc
        
        switch bps
            when 1
                console.log 1
                
            when 2
                #console.log decode_buffer[0]
                @emit 'data', decode_buffer
                
            when 3
                console.log 3
        
        return