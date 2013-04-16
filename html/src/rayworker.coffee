#
#   Worker thread for Zen Photon Garden.
#
#   Workers are used for our CPU-intensive computing tasks:
#
#       - Rendering a scene to a ray histogram
#       - Combining multiple ray histograms
#       - Rendering a combined ray histogram to a bitmap
#
#   Copyright (c) 2013 Micah Elizabeth Scott <micah@scanlime.org>
#
#   Permission is hereby granted, free of charge, to any person
#   obtaining a copy of this software and associated documentation
#   files (the "Software"), to deal in the Software without
#   restriction, including without limitation the rights to use,
#   copy, modify, merge, publish, distribute, sublicense, and/or sell
#   copies of the Software, and to permit persons to whom the
#   Software is furnished to do so, subject to the following
#   conditions:
#
#   The above copyright notice and this permission notice shall be
#   included in all copies or substantial portions of the Software.
#
#   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
#   EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
#   OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
#   NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
#   HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
#   WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
#   FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
#   OTHER DEALINGS IN THE SOFTWARE.
#


#####################################################################
# asm.js setup

# Polyfill from https://developer.mozilla.org/en-US/docs/JavaScript/Reference/Global_Objects/Math/imul
if not Math.imul
    Math.imul = (a, b) ->
        ah = (a >>> 16) & 0xffff
        al = a & 0xffff
        bh = (b >>> 16) & 0xffff
        bl = b & 0xffff
        return ((al * bl) + (((ah * bl + al * bh) << 16) >>> 0)|0)

heap = new ArrayBuffer(4 * 1024 * 1024)
F32 = new Float32Array(heap)
U32 = new Uint32Array(heap)

stdlib =
    Math: Math
    Uint32Array: Uint32Array
    Float32Array: Float32Array

AsmFn = AsmModule(stdlib, {}, heap)


#####################################################################
# Utilities


alloc32 = (ptr, width, height) ->
    return ptr + (4 * width * height)


allocRandomBuffer = (ptr) ->
    # Fill a buffer full of random numbers, for use by our asm.js code.
    # We can reuse random numbers to improve speed, plus this prevents us
    # from needing to call a non-asm function from our inner loops.

    for n in [ptr .. ptr + 0xFFFF] by 4
        F32[ptr>>2] = Math.random()
    return ptr + 0x10000


allocScene = (ptr, scene) ->
    # Transcribe our scene from an array of Segment objects into a flat list of floats in our heap

    for s in scene
        dx = s.x1 - s.x0
        dy = s.y1 - s.y0

        # Calculate normal
        len = Math.sqrt(dx*dx + dy*dy)
        xn = -dy / len
        yn = dx / len

        # Calculate ray probabilities
        d1 = s.diffuse
        r2 = d1 + s.reflective
        t3 = r2 + s.transmissive

        F32[(ptr + 0 ) >> 2] = s.x0
        F32[(ptr + 4 ) >> 2] = s.y0
        F32[(ptr + 8 ) >> 2] = dx
        F32[(ptr + 12) >> 2] = dy
        F32[(ptr + 16) >> 2] = d1
        F32[(ptr + 20) >> 2] = r2
        F32[(ptr + 24) >> 2] = t3
        F32[(ptr + 28) >> 2] = xn
        F32[(ptr + 32) >> 2] = yn

        ptr += 64
    return ptr

traceWithHeap = (ptr, msg) ->
    # Middleman for AsmFn.trace(), helps set up the heap first

    # Heap layout
    counts = ptr
    randBuffer = alloc32(counts, msg.width, msg.height)
    sceneBegin = allocRandomBuffer(randBuffer)
    sceneEnd = allocScene(sceneBegin, msg.segments)

    AsmFn.trace(counts, msg.width, msg.height, msg.lightX, msg.lightY, msg.numRays, sceneBegin, sceneEnd, randBuffer)


#####################################################################
# Job handlers


@job_trace = (msg) ->
    # Trace rays, and transfer the entire heap back to the caller to avoid copying results.

    return #xxx

    counts = 0
    endCounts = alloc32(counts, msg.width, msg.height)
    traceWithHeap(counts, msg)
    result = heap.slice(counts, endCounts)

    @postMessage({
        job: msg.job,
        cookie: msg.cookie,
        numRays: msg.numRays,
        counts: heap,
    }, [heap])


@job_accumulate = (msg) ->
    # Accumulate samples from another thread's raytracing. No response.

    return #xxx

    # Heap layout
    accumulator = 0
    src = alloc32(accumulator, msg.width, msg.height)

    if msg.cookie > @cookie
        # Newer cookie; start over

        U32.set(msg.counts, accumulator>>2)
        @raysTraced = msg.numRays
        @cookie = msg.cookie

    else if msg.cookie == @cookie
        # Accumulator matches.
        # Use our saturation-robust accumulator loop only if enough rays
        # have been cast such that saturation is a concern.

        U32.set(msg.counts, src>>2)
        n = msg.width * msg.height
        @raysTraced += msg.numRays

        if @raysTraced >= 0xffffff
            AsmFn.accumLoopSat(src, accumulator, n)
        else
            AsmFn.accumLoop(src, accumulator, n)


@job_render = (msg) ->
    # Using the current accumulator state, render an RGBA image.
    # Copies the pixel data into a smaller buffer, which is transferred back.

    # Heap layout
    accumulator = 0
    pixels = alloc32(accumulator, msg.width, msg.height)
    end = alloc32(pixels, msg.width, msg.height)

    # Brightness calculation
    br = Math.exp(1 + 10 * msg.exposure) / @raysTraced

    n = msg.width * msg.height
    AsmFn.renderLoop(accumulator, pixels, n, br)
    result = heap.slice(pixels, end)

    @postMessage({
        job: msg.job,
        cookie: @cookie,
        raysTraced: @raysTraced,
        pixels: result,
    }, [result])


@job_firstTrace = (msg) ->
    # Trace rays, replace the entire accumulator buffer with the new counts,
    # and return a rendered image. This is the fastest way to initialize the
    # accumulator with data from a modified scene, so this is what we use during
    # interactive rendering.

    # Heap layout
    accumulator = 0

    traceWithHeap(accumulator, msg)
    @raysTraced = msg.numRays
    @cookie = msg.cookie

    @job_render(msg)


@onmessage = (event) =>
    msg = event.data
    this['job_' + msg.job](msg)