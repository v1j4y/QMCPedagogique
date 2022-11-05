using Revise
using DelimitedFiles
using Printf
using BenchmarkTools
using Transducers
using FLoops
using BangBang: mergewith!!
using MicroCollections: SingletonDict
using BenchmarkTools
using Revise
using LaTeXStrings
using StaticArrays
using BitBasis
using TimerOutputs
using Pkg
using ProgressMeter
using Measurements

#Pkg.develop(path="/home/chilkuri/.julia/dev/slaterlibjl")
#Pkg.develop(path="/home/chilkuri/Documents/codes/julia/merge_utils")
using slaterlibjl

"""
Determinant object `Det`

# Fields
- α : alpha determinant
- β : beta determinant
"""
mutable struct Det{N, T}
    α::Vector{T}
    β::Vector{T}
    sgn::Bool
    function Det{N, T}() where {N, T}
        α    = Vector{T}(zeros(T, N));
        β    = Vector{T}(zeros(T, N));
        sgn  = true;
        new(α, β, sgn)
    end
    function Det{N, T}(α, β, sgn) where {N, T}
        new(α, β, sgn)
    end
end

"""
Determinant object `Context`

# Fields
- idlist       : contains the orbital indices p and q (p -> q)
- matelem      : contains the corresponding matrix elements for excitation pq
- exlist       : required for the spawining step to store ndet
- idset        : buffer to collect all the set bits (in call to to_orbital_list)
- pijlist      : required for the spawining step to store probabilities
- detbuffer    : temporary buffer
- detlist      : (per thread) required to store the determinants during DMC
- ndetlist     : (per thread) stores the number of walkers for each determinant
- idxlist      : the number of spawned determinants
- detlistmain  : the main list of determinants after merge
- ndetlistmain : the main list of walkers after merge
- ndetmain     : total number of unique determinants
- jmp          : stores the size N (needed for calling to_orbital_list_multi)
"""
mutable struct Context{N, M, K, L}
    idlist           ::Array{UInt32}
    matelem          ::Matrix{Float64}
    exlist           ::Matrix{Int64}
    idset            ::Vector{UInt32}
    pijlist          ::Matrix{Float64}
    bigOne           ::Vector{Det{M, UInt64}}
    detlist          ::Array{Det{M, UInt64}, 2}
    detlistcopy      ::Array{Det{M, UInt64}, 2}
    ndetlist         ::Matrix{Int64}
    ndetlistcopy     ::Matrix{Int64}
    detlistmain      ::Array{Det{M, UInt64}}
    detlistmaincopy  ::Array{Det{M, UInt64}}
    ndetlistmain     ::Vector{Int64}
    ndetlistmaincopy ::Vector{Int64}
    ndetmain         ::Int64
    idxlist          ::Vector{UInt64}
    jmp              ::Int64
    function Context{N, M, K, L}() where {N, M, K, L}
        idlist  = Array{UInt32}(zeros(N, 2, K))
        matelem = Matrix{Float64}(zeros(N, K))
        exlist  = Matrix{UInt32}(zeros(N, K));
        idset   = Vector{UInt32}(zeros(L));
        pijlist = Matrix{Float64}(zeros(N, K));
        bigOne  = Vector{Det{M, UInt64}}(zeros(Det{M, UInt64}, K));
        detlist = Array{Det{M, UInt64}, 2}(undef, N, K);
        detlistcopy     = Array{Det{M, UInt64}, 2}(undef, N, K);
        detlistmain     = Array{Det{M, UInt64}}(undef, N);
        detlistmaincopy = Array{Det{M, UInt64}}(undef, N);
        for i in 1:N
            for j in 1:K
                detlist[i, j] = Det{M, UInt64}(zeros(UInt64,M),zeros(UInt64,M),true);
                detlistcopy[i, j] = Det{M, UInt64}(zeros(UInt64,M),zeros(UInt64,M),true);
            end
            detlistmain[i] = Det{M, UInt64}(zeros(UInt64,M),zeros(UInt64,M),true);
            detlistmaincopy[i] = Det{M, UInt64}(zeros(UInt64,M),zeros(UInt64,M),true);
        end
        ndetlist        = Matrix{Int64}(zeros(N, K));
        ndetlistcopy    = Matrix{Int64}(zeros(N, K));
        ndetlistmain    = Vector{Int64}(zeros(N));
        ndetlistmaincopy= Vector{Int64}(zeros(N));
        idxlist = Vector{UInt64}(zeros(K));
        jmp = N;
        new(idlist, matelem, exlist, idset, pijlist, bigOne, detlist, detlistcopy, ndetlist, ndetlistcopy, detlistmain, detlistmaincopy, ndetlistmain, ndetlistmaincopy, Int64(0), idxlist, jmp)
    end
end
function Context{N, M, K}() where {N, M, K}
    Context{N, M, K, N * K}()
end

Base.:(==)(a::Det,b::Det) = begin
    N_int = length(a.α)
    issame = true
    for i in 1:N_int
        if a.α[i] != b.α[i]
            issame = false
            break
        end
    end
    if ~issame
        return(issame);
    end
    for i in 1:N_int
        if a.β[i] != b.β[i]
            issame = false
            break
        end
    end
    return(issame)
end

Base.hash(a::Det, h::UInt) = begin
    N_int = length(a.α)
    res = hash(:Det, h)
    for i in 1:N_int
        res = hash(a.α[i], res)
    end
    for i in 1:N_int
        res = hash(a.β[i], res)
    end
    return(res)
end

Base.isless(a::Det, b::Det) = begin
    N_int = length(a.α)
    res = true
    iseq = false
    for i in 1:N_int
        if a.α[i] > b.α[i]
            res = false
            break
        elseif a.α[i] == b.α[i]
            iseq = true
        end
    end
    if ~iseq
        return(res)
    end
    for i in 1:N_int
        if a.β[i] >= b.β[i]
            res = false
            break
        end
    end
    return(res)
end

Base.copy!(a::Det, b::Det) = begin
    N_int = length(a.α)
    for i in 1:N_int
        b.α[i] = a.α[i]
        b.β[i] = a.β[i]
    end
end

Base.zero(::Type{Det{N, T}}) where {N, T} = begin
    return(Det{N, T}(zeros(T, N),zeros(T, N),true))
end

Broadcast.broadcastable(a::Det) = (a,);

function Base.show(io::IO,a::Det)
    N_int = length(a.α)
    for i in 1:N_int
        Printf.@printf(io,"\t %u %s \n\t %u %s",a.α[i], bitstring(a.α[i]), a.β[i], bitstring(a.β[i]))
    end
end

"""
Or
"""
function detor!(a::Vector, b::Vector, c::Vector)
    N_int = length(a)
    nset = 0
    for i in 1:N_int
        c[i] = a[i] | b[i]
    end
end

"""
XOr
"""
function detxor!(a::Vector, b::Vector, c::Vector)
    N_int = length(a)
    nset = 0
    for i in 1:N_int
        c[i] = a[i] ^ b[i]
    end
end

"""
And
"""
function detand!(a::Vector, b::Vector, c::Vector)
    N_int = length(a)
    nset = 0
    for i in 1:N_int
        c[i] = a[i] & b[i]
    end
end

function detand!(a::Vector, b::Vector, c::Vector)
    N_int = length(a)
    nset = 0
    for i in 1:N_int
        c[i] = a[i] & b[i]
    end
end

"""
Popcount
"""
function popcount(a::SVector)
    N_int = length(a)
    nset = 0
    for i in 1:N_int
        nset += count_ones(a[i])
    end
    return(nset)
end

"""
Calculate diagonal energy
"""
function hdiag!(a::Det, work::Vector, norb::Int64, Uval::Float64)
    detand!(a.α,a.β,work)
    thid = Threads.threadid();
    N_int = length(a.α)
    res = 0
    for i in 1:N_int
        res = count_ones(work[i]);
    end
    return(Uval*res);
end

"""
Swap bits
"""
function swapbits!(ctxt, x::Det, p, q, type)
    N_int = length(x.α)
    thid = Threads.threadid();
    idx = ctxt.idxlist[thid];
    dettmp = ctxt.detlist[idx+1,thid];
    if type=="alpha"
        unset_bit(N_int, x.α, dettmp.α, p)
        set_bit(N_int, dettmp.α, dettmp.α, q)
        for i in 1:N_int
            dettmp.β[i] = x.β[i];
        end
    else
        unset_bit(N_int, x.β, dettmp.β, p)
        set_bit(N_int, dettmp.β, dettmp.β, q)
        for i in 1:N_int
            dettmp.α[i] = x.α[i];
        end
    end
    ctxt.idxlist[thid] += 1;
end

"""
Calculate mono excitations possible on input determinant.
Returns
 Number of alpha and beta excitations
 List of each excitation pair (h,p)
"""
function getNNNex!(ctxt::Context, det, cnt, norb, to)
    N_int = length(det)
    thid = Threads.threadid();
    jmpid = ctxt.jmp*(thid-1)
    nset = to_orbital_list_multi(N_int, det, ctxt.idset, jmpid)
    nprev = cnt - 1
    phase = 1.0
    for idx in 1:nset
        idi = ctxt.idset[jmpid + idx]
        idip1set=false
        idip2set=false
        idim1set=false
        idim2set=false
        #for j in 1:nset
            if ctxt.idset[jmpid + idx + 1]==idi+1
                idip1set=true
            end
            if ctxt.idset[jmpid + idx + 2]==idi+2
                idip2set=true
            end
        if idx > 1
            if ctxt.idset[jmpid + idx - 1]==idi-1
                idim1set=true
            end
        end
        if idx > 2
            if ctxt.idset[jmpid + idx - 2]==idi-2
                idim2set=true
            end
        end
        #end
        if (~idip1set) && (idi+1)<=norb
            phase = 1.0;
            ctxt.idlist[cnt,1, thid] =idi
            ctxt.idlist[cnt,2, thid] =idi+1
            ctxt.matelem[cnt, thid] =phase
            cnt = cnt + 1;
        end
        #if (~idip2set) && (idi+2)<=norb
        #    nel = ifelse(idip1set,1,0)
        #    phase = 2.0*(-1.0)^nel;
        #    ctxt.idlist[cnt,1, thid] =idi
        #    ctxt.idlist[cnt,2, thid] =idi+2
        #    ctxt.matelem[cnt, thid] = phase
        #    cnt = cnt + 1;
        #end
        if (~idim1set) && (idi-1)>0
            phase = 1;
            ctxt.idlist[cnt,1, thid] = idi;
            ctxt.idlist[cnt,2, thid] = idi-1;
            ctxt.matelem[cnt, thid] = phase  ;
            cnt = cnt + 1;
        end
        #if (~idim2set) && (idi-2)>0
        #    nel = ifelse(idim1set,1,0)
        #    phase = 2.0*(-1.0)^nel;
        #    ctxt.idlist[cnt,1, thid] =idi
        #    ctxt.idlist[cnt,2, thid] =idi-2
        #    ctxt.matelem[cnt, thid] = 0.0;#phase
        #    cnt = cnt + 1;
        #end
    end
    return(cnt - 1 - nprev)
end

function getNNNmonosJlist!(ctxt, detinp::Det, norb, to)
    cnt = 1
    ndeta = getNNNex!(ctxt, detinp.α, cnt, norb, to)
    cnt = ndeta + 1
    ndetb = getNNNex!(ctxt, detinp.β, cnt, norb, to)
    return(ndeta, ndetb)
end

"""
Searchsortedfirst alternative
"""
function searchsortedfirstmy(ctxt, ntot)
    rnd = rand();
    thid = Threads.threadid();
    if 0 < rnd  && rnd <= ctxt.pijlist[1, thid]
        return(1)
    end
    for i in 1:ntot-1
        if ctxt.pijlist[i, thid] < rnd && rnd <= ctxt.pijlist[i+1, thid]
            return(i + 1)
        end
    end
    println(thid," Something went wrong ",ctxt.pijlist[1:ntot,thid])
    return(-1)
end

"""
Merge a list of dets
    Merge detlist for kth thread
"""
function mergedetslist!(ctxt, idxold, k)
    ndet = ctxt.idxlist[k];
    N_int = length(ctxt.bigOne[1].α)
    idxlist = idxold;
    idfound = 0;
    olddet = false;
    for i in idxold+1:ndet
        olddet = false;
        idfound = 0;
        for j in 1:i-1
            if(ctxt.detlist[i,k] == ctxt.detlist[j,k])
                olddet = true;
                idfound = j;
                break;
            end
        end
        if (~olddet)
            idxlist += 1
            if idxlist != i
                copy!(ctxt.detlist[i,k], ctxt.detlist[idxlist, k])
                ctxt.ndetlist[idxlist,k] = ctxt.ndetlist[i,k];
            end
        else
            ctxt.ndetlist[idfound,k] = ctxt.ndetlist[idfound,k] + ctxt.ndetlist[i,k];
        end
    end
    ctxt.idxlist[k] = idxlist;
    return(idxlist)
end

"""
Merge a list of dets
    Merge detlist for kth thread
"""
function mergedetslistdict!(ctxt, idxold, k, dictall)
    ndet = ctxt.idxlist[k];
    N_int = length(ctxt.bigOne[1].α)
    idxlist = idxold;
    idfound = 0;
    olddet = false;
    for i in idxold+1:ndet
        olddet = false;
        idfound = 0;
        if haskey(dictall, ctxt.detlist[i, k])
            olddet = true
            idfound = dictall[ctxt.detlist[i, k]]
        end

        if (~olddet)
            idxlist += 1
            if idxlist != i
                copy!(ctxt.detlist[i, k], ctxt.detlist[idxlist, k])
                ctxt.ndetlist[idxlist, k] = ctxt.ndetlist[i, k];
                dictall[ctxt.detlist[idxlist, k]] = idxlist + 1
            end
        else
            ctxt.ndetlist[idfound,k] = ctxt.ndetlist[idfound,k] + ctxt.ndetlist[i,k];
        end
    end
    ctxt.idxlist[k] = idxlist;
    return(idxlist)
end

function getlocalenergy(ctxt, x, norb, τ, t, U, to)

    thid = Threads.threadid()

    N_int = length(x.α)
    nexa = count_nearest_neighbors(N_int, x.α, norb)
    nexb = count_nearest_neighbors(N_int, x.β, norb)

    Hii = hdiag!(x, ctxt.bigOne[thid].α, norb, U);

    ELi = Hii
    for i in 1:nexa+nexb
        ELi = ELi + t
    end

    return(Hii, ELi, nexa, nexb)
end

function preparepijlist!(ctxt, x, norb, τ, t, U, to)

    # Find mono's
    nexa,nexb=getNNNmonosJlist!(ctxt, x, norb,to)

    thid = Threads.threadid();

    Hii = hdiag!(x, ctxt.bigOne[thid].α, norb, U);

    ELi = Hii
    for i in 1:nexa+nexb
        ELi = ELi + t*ctxt.matelem[i,thid]
    end

    ctxt.pijlist[1, thid] = 1.0 - τ * (Hii - ELi)
    idlstip = ctxt.pijlist[1, thid]
    idlsti = 0.0
    for i in 1:nexa+nexb
        idlsti = τ*abs(ctxt.matelem[i, thid])
        idlstip = idlstip + idlsti
        ctxt.pijlist[i+1, thid] = idlstip
    end
    return(Hii, ELi, nexa, nexb)
end

function preparepijlist_nodiag!(ctxt, x, norb, τ, t, U, to)

    # Find mono's
    nexa,nexb=getNNNmonosJlist!(ctxt, x, norb,to)

    thid = Threads.threadid();

    Hii = hdiag!(x, ctxt.bigOne[thid].α, norb, U);

    ELi = Hii
    for i in 1:nexa+nexb
        ELi = ELi + t*ctxt.matelem[i,thid]
    end

    idlstip = 0.0
    idlsti = 0.0
    for i in 1:nexa+nexb
        idlsti = abs(ctxt.matelem[i, thid])/(Hii - ELi)
        idlstip = idlstip + idlsti
        ctxt.pijlist[i, thid] = idlstip
    end
    return(Hii, ELi, nexa, nexb)
end

function spawn_branch_l!(x::Det, ndet::Int64, norb::Int, τ::Float64, t::Float64, U::Float64, ET::Float64, iter::Int64, ndimmax::Int64, ctxt::Context, to)
    #x = ctxt.detlistmain[detidmain]
    #ndet = ctxt.ndetlistmain[detidmain]
    ndet = abs(ndet)
    dictall=Dict()

    thid = Threads.threadid();
    N_int = length(x.α);

    # perform mono's and prepare pijlist
    Hii, ELi, nexa, nexb = preparepijlist!(ctxt, x, norb, τ, t, U, to)

    # idxold for mergelist
    idxold = max(1,ctxt.idxlist[1])

    idex = 1
    ndetj = 0
    pij=0.0

    # Spawn and branching
    for i in 1:ndet
        idex = searchsortedfirstmy(ctxt,nexa+nexb+1)

        # Brach or death
        randval = rand()
        if idex != 1
            wij = 1.0
        else
            numer = 1.0 - τ * (Hii - ET)
            denom = 1.0 - τ * (Hii - ELi)
            wij = numer/denom
        end
        nnew = floor(Int64, wij)
        if rand() < wij - nnew
            nnew += 1
        end
        ctxt.exlist[idex, thid] = ctxt.exlist[idex, thid] + nnew
    end

    if iter < 4
        ctxt.exlist[1, thid] = ndet
        ctxt.exlist[2:nexa+nexb+1, thid] .= 1
    end

    # Spawn to same determinant
    if ctxt.exlist[1, thid] > 0
        copy!(x, ctxt.detlist[ctxt.idxlist[thid] + 1, thid])
        ctxt.ndetlist[ctxt.idxlist[thid]+1, thid] = ctxt.exlist[1,thid]
        ctxt.idxlist[thid] += 1
    end
    # Spawn to new determinants
    for idex in 1:nexa+nexb
        ndetj = ctxt.exlist[idex+1, thid]
        if ndetj > 0
            id1=ctxt.idlist[idex,1, thid]
            id2=ctxt.idlist[idex,2, thid]

            if idex <= nexa
                swapbits!(ctxt, x, id1, id2, "alpha")
            else
                swapbits!(ctxt, x, id1, id2, "beta")
            end

            ctxt.ndetlist[ctxt.idxlist[thid],thid] = ndetj;
        end
    end
    mergedetslistdict!(ctxt, idxold, thid, dictall);

    for i in 1:nexa+nexb+1
        ctxt.pijlist[i, thid] = 0.0
        ctxt.exlist[i, thid] = 0
        ctxt.idlist[i,1, thid] = 0
        ctxt.idlist[i,2, thid] = 0
        ctxt.matelem[i, thid] = 0.0
    end
end

function spawn_branch_main!(x::Det, ndet::Int64, norb,τ,t,U,ET,nadvance::Int,iter::Int64,ndimmax::Int64, ctxt::Context, to)
    nwalk = 1
    thid = Threads.threadid()
    if nadvance == 0
        nadvance=rand(1:100)
    end
    for iad in 1:nadvance
        for i in 1:nwalk
            #if iad == 1
            #    detI = x
            #    ndetI = ndet
            #else
            #    detI = ctxt.detlist[i,1]
            #    ndetI = ctxt.ndetlist[i,1]
            #end
            spawn_branch_list = spawn_branch_m!(x, ndet, norb,τ,t,U,ET,iter,ndimmax,ctxt,to)
        end
        nwalk = ctxt.idxlist[thid]
    end
    return(1)
end

function spawn_branch_m!(x::Det, ndet::Int64, norb::Int, τ::Float64, t::Float64, U::Float64, ET::Float64, iter::Int64, idxmain::Int64, ctxt::Context, to)
    #x = ctxt.detlistmain[detidmain]
    #ndet = ctxt.ndetlistmain[detidmain]
    ndet = abs(ndet)
    #dictall=Dict()

    thid = Threads.threadid();
    N_int = length(x.α);

    # perform mono's and prepare pijlist
    Hii, ELi, nexa, nexb = getlocalenergy(ctxt, x, norb, τ, t, U, to)

    # idxold for mergelist
    idxold = max(1,ctxt.idxlist[thid])

    idex = 1
    ndetj = 0
    pij=0.0
    numer = 1.0 - τ * (Hii - ET)
    denom = 1.0 - τ * (Hii - ELi)
    wij = numer/denom
    wijex = 0.0
    done_pijlist = false


    # Spawn and branching
    for i in 1:ndet

        # Brach or spawn
        randval = rand()
        if randval > denom
            if ~done_pijlist
                # prepare pij list
                Hii, ELi, nexa, nexb = preparepijlist_nodiag!(ctxt, x, norb, τ, t, U, to)
                done_pijlist = true
            end

            idex = searchsortedfirstmy(ctxt,nexa+nexb)
            idex = idex + 1 # 1 is for the parent itself
            wijex = 1.0
        else
            wijex = wij
            idex = 1
        end
        nnew = floor(Int64, wijex)
        if rand() < wijex - nnew
            nnew += 1
        end
        ctxt.exlist[idex, thid] = ctxt.exlist[idex, thid] + nnew
    end

    if iter < 4
        #println(" -- Generation -- ")
        # prepare pij list
        Hii, ELi, nexa, nexb = preparepijlist_nodiag!(ctxt, x, norb, τ, t, U, to)
        done_pijlist = true

        ctxt.exlist[1, thid] = ndet + 1
        ctxt.exlist[2:nexa+nexb+1, thid] .= 1
    end

    # Spawn to same determinant
    if ctxt.exlist[1, thid] > 0
        #copy!(x, ctxt.detlistmaincopy[idxmain])
        ctxt.ndetlistmaincopy[idxmain] = ctxt.exlist[1, thid]
        ctxt.exlist[1, thid] = 0
    end
    # Spawn to new determinants
    for idex in 1:nexa+nexb
        ndetj = ctxt.exlist[idex+1, thid]
        if ndetj > 0
            id1=ctxt.idlist[idex,1, thid]
            id2=ctxt.idlist[idex,2, thid]

            if idex <= nexa
                swapbits!(ctxt, x, id1, id2, "alpha")
            else
                swapbits!(ctxt, x, id1, id2, "beta")
            end

            ctxt.ndetlist[ctxt.idxlist[thid],thid] = ndetj;
            ctxt.exlist[idex+1, thid] = 0
        end
    end
    #mergedetslistdict!(ctxt, idxold, thid, dictall);

    #for i in 1:nexa+nexb+1
    #    ctxt.pijlist[i, thid] = 0.0
    #    ctxt.exlist[i, thid] = 0
    #    ctxt.idlist[i,1, thid] = 0
    #    ctxt.idlist[i,2, thid] = 0
    #    ctxt.matelem[i, thid] = 0.0
    #end
end

function launchspawn!(norb, τ, t, U, ET, nadvance, iter, ndimmax, nthreads, tlst, ctxt::Context, to, dictmain)
    nuniqdets = ctxt.ndetmain
    res = 0
    ndead = 0
    nintmin = - ( 1 << 63 )
    Threads.@threads for i in 1:ctxt.ndetmain
        #println("i=",i," x=",ctxt.detlistmain[i])
        #Printf.@printf(" %#010x", hash(ctxt.detlistmain[i]))
        ctxt.ndetlistmaincopy[i] = nintmin
        spawn_branch_main!(ctxt.detlistmain[i], ctxt.ndetlistmain[i], norb, τ, t, U, ET, nadvance, iter, i, ctxt, to);
        if ctxt.ndetlistmaincopy[i] != nintmin
            idx = dictmain[hash(ctxt.detlistmain[i])]
            ctxt.ndetlistmain[idx] = ctxt.ndetlistmaincopy[i]
        else
            # Remove dead walkers
            idx = dictmain[hash(ctxt.detlistmain[i])]
            ctxt.ndetlistmain[idx] = 0
            ndead += 1
        end
    end
    return(ndead)
end

"""
Merge a list of dets
    Merge detlist for all threads
"""
function mergedetslistall!(ctxt::Context, nthreads::Int, dictmain)
    # Copy first thread list
    # these are already merged
    ndetmain = 0;
    ndet = Int64(ctxt.idxlist[1]);
    N_int = length(ctxt.bigOne[1].α)
    for i in 1:ndet
        if ~haskey(dictmain, ctxt.detlist[i,1])
            ndetmain += 1
            copy!(ctxt.detlist[i, 1], ctxt.detlistmain[ndetmain])
            ctxt.ndetlistmain[ndetmain] = ctxt.ndetlist[i,1];
            ctxt.ndetlist[i,1] = 0;
            dictmain[ctxt.detlist[i,1]] = ndetmain
        else
            idfound = dictmain[ctxt.detlist[i, 1]]
            ctxt.ndetlistmain[idfound] += ctxt.ndetlist[i,1];
        end
    end
    ctxt.idxlist[1] = 0;

    if nthreads > 1
        for k in 2:nthreads
            ndet = ctxt.idxlist[k];
            ispresent = true;
            idfound = 0;
            for i in 1:ndet
                ispresent = false;
                idfound = 0;
                #for j in 1:ndetmain
                #    if(ctxt.detlist[i,k] == ctxt.detlistmain[j])
                #        ispresent = true;
                #        idfound = j;
                #        break;
                #    end
                #end
                if haskey(dictmain, ctxt.detlist[i,k])
                    ispresent = true;
                    idfound = dictmain[ctxt.detlist[i,k]]
                end
                if (~ispresent)
                    ndetmain += 1
                    copy!(ctxt.detlist[i, k], ctxt.detlistmain[ndetmain])
                    ctxt.ndetlistmain[ndetmain] = ctxt.ndetlist[i,k];
                    dictmain[ctxt.detlist[i,k]] = ndetmain
                else
                    ctxt.ndetlistmain[idfound] = ctxt.ndetlistmain[idfound] + ctxt.ndetlist[i,k];
                end
                ctxt.ndetlist[i,k] = 0;
            end
            ctxt.idxlist[k] = 0;
        end
    end
    ctxt.ndetmain = ndetmain;
    return(ndetmain)
end

function mergecustom!(ctxt, idxlist, listoflists, mergedlist,  dimlistarray)
    idx = 0
    idxmain = 1
    idj = 0
    dimlist, nlists = size(listoflists)
    niter = 0
    nitermax = 1000000
    checkid = 0
    ndetj = 0
    N_int = length(ctxt.bigOne[1].α)
    deta = zeros(UInt64, N_int)
    detb = zeros(UInt64, N_int)
    for i in 1:N_int
        deta[i] = UInt64((1 << 63) - 1)
        detb[i] = UInt64((1 << 63) - 1)
    end
    minlstStore = Det{N_int, UInt64}(deepcopy(deta), deepcopy(detb), true);
    minlst      = deepcopy(Det{N_int, UInt64}(deepcopy(deta), deepcopy(detb), true));
    continueiter = true
    while continueiter
        copy!(minlstStore, minlst)

        # First do the main list
        if idxmain > ctxt.ndetmain
            continue
        end
        if minlst > ctxt.detlistmaincopy[idxmain]
            copy!(ctxt.detlistmaincopy[idxmain], minlst)
            ndetj = ctxt.ndetlistcopy[idxmain]
            idj = j
        elseif minlst == ctxt.detlistmaincopy[idxmain]
            ndetj += ctxt.ndetlistmaincopy[idxmain]
            idxlist[j] += 1
        end

        # Now the spawned list
        idj = -1
        for j in 1:nlists
            if idxlist[j] > dimlistarray[j]
                continue
            end
            if minlst > listoflists[idxlist[j], j]
                copy!(listoflists[idxlist[j], j], minlst)
                ndetj = ctxt.ndetlist[idxlist[j], j]
                idj = j
            elseif minlst == listoflists[idxlist[j], j]
                ndetj += ctxt.ndetlist[idxlist[j], j]
                idxlist[j] += 1
            end
        end
        if idj != -1
            idxlist[idj] += 1
        else
            idxmain += 1
        end

        idx += 1
        copy!(minlst, mergedlist[idx])
        ctxt.ndetlistmain[idx] = ndetj
        niter += 1
        if checkid == nlists
            continueiter = false
        end
        checkid = 0
        for j in 1:nlists
            if idxlist[j] >= dimlistarray[j]
                checkid += 1
            end
        end
    end
    return(idx)
end

function sortcustom!(listoflists, numoflists, indexlists, listoflistscopy, numoflistscopy, dimlistarray, nlists, to)
    @timeit to "sortmain" begin
    Threads.@threads for i in 1:nlists
        p = Int64(dimlistarray[i])
        sortperm!(view(indexlists, i, 1:p), view(listoflists, 1:p, i))
    end
    end
    @timeit to "permute" begin
    # Apply permutations
    Threads.@threads for i in 1:nlists
        for j in 1:dimlistarray[i]
            p = indexlists[i, j]
            copy!(listoflists[p, i], listoflistscopy[j, i])
            numoflistscopy[j, i]  = numoflists[p, i]
        end
    end
    Threads.@threads for i in 1:nlists
        for j in 1:dimlistarray[i]
            p = indexlists[i, j]
            copy!(listoflistscopy[j, i], listoflists[j, i])
            numoflists[j, i]  = numoflistscopy[j, i]
        end
    end
    end
end

"""
Merge a list of dets
    Merge detlist for all threads
"""
function mergedetslistall_improv!(ctxt::Context, nthreads::Int, to)

    # Copy surviving dets which are guaranteed sorted
    nintmin = - ( 1 << 63 )
    ndetmain = 0
    for i in 1:ctxt.ndetmain
        if ctxt.ndetlistmaincopy[i] != nintmin
            ndetmain += 1
            copy!(ctxt.detlistmaincopy[ndetmain], ctxt.detlistmain[i])
        end
    end
    println("Ndetmain=",ndetmain)
    ctxt.ndetmain = ndetmain

    nlist = nthreads;
    dimlist = maximum(ctxt.idxlist)
    indexlist = zeros(Int64, nlist, dimlist)

    # Sort lists
    @timeit to "sort" sortcustom!(ctxt.detlist, ctxt.ndetlist, indexlist, ctxt.detlistcopy, ctxt.ndetlistcopy, ctxt.idxlist, nthreads, to)

    indexlist = ones(Int64, nlist)
    # Merge lists deleting duplicates
    @timeit to "mergecustom" ndetmain = mergecustom!(ctxt, indexlist, ctxt.detlist, ctxt.detlistmain, ctxt.idxlist)

    for i in 1:nlist
        ctxt.idxlist[i] = 0
    end

    ctxt.ndetmain = ndetmain;
    return(ndetmain)
end

"""
Merge a list of dets
    Merge detlist for all threads
"""
function mergedetslistall_dict!(ctxt::Context, nthreads::Int, to, dictmain)

    # Copy surviving dets which are guaranteed sorted
    nintmin = - ( 1 << 63 )
    #ndetmain = length(dictmain)

    # Remove dead walkers
    ndetmain = 0
    for i in 1:ctxt.ndetmain
        if ctxt.ndetlistmaincopy[i] != nintmin
            ndetmain += 1
            copy!(ctxt.detlistmain[i], ctxt.detlistmaincopy[ndetmain])
            ctxt.ndetlistmain[ndetmain] = ctxt.ndetlistmaincopy[i]
        else
            delete!(dictmain, hash(ctxt.detlistmain[i]))
        end
    end

    for i in 1:ndetmain
        copy!(ctxt.detlistmaincopy[i], ctxt.detlistmain[i])
        dictmain[hash(ctxt.detlistmain[i])] = i
        #println(i," ", ctxt.ndetlistmain[i])
    end

    for i in 1:nthreads
        for j in 1:ctxt.idxlist[i]
            if haskey(dictmain, hash(ctxt.detlist[j, i]))
                idx = dictmain[hash(ctxt.detlist[j, i])]
                ctxt.ndetlistmain[idx] += ctxt.ndetlist[j, i]
            else
                ndetmain += 1
                dictmain[hash(ctxt.detlist[j, i])] = ndetmain;
                ndeti = ctxt.ndetlist[j, i]
                ctxt.ndetlistmain[ndetmain] = ndeti
                copy!(ctxt.detlist[j, i], ctxt.detlistmain[ndetmain])
                #println(ndetmain," ",ctxt.detlist[j,i])
            end
        end
        ctxt.idxlist[i] = 0
    end

    ctxt.ndetmain = ndetmain;
    return(ndetmain)
end

function adjustShift(Sold,ζ,τ,Nw,Nwold,A)
    if Nw == 0
        return(Sold + 0.0001)
    end
    Snew = Sold - log(Nw/Nwold) * ζ / (A * τ);
    return(Snew)
end

function isingdet(norb::Int, nalpha::Int; type="alpha")
    N_int = ceil(Int,norb/64);
    nbeta = norb - nalpha
    detintlist = [];
    for j in 1:N_int
        if type=="alpha"
            detint = bmask(UInt64, [2*(i-1) + 1 for i in 1:min(nalpha,32)])
        else
            detint = bmask(UInt64, [2*(i-1) + 2 for i in 1:min(nbeta,32)])
        end
        push!(detintlist, detint)
        nalpha = nalpha - 32;
        nbeta = nbeta - 32;
        if nalpha <= 0
            break
        elseif nbeta <= 0
            break
        end
    end
    return(detintlist)
end

function generateInitialGuess!(norb, nalpha, ndet, ctxt; ndetmain=1)
    N_int = ceil(Int,norb/64);
    nbeta = norb - nalpha
    deta = Vector{UInt64}(isingdet(norb, nalpha, type="alpha"));
    detb = Vector{UInt64}(isingdet(norb, nalpha, type="beta"));
    #println(deta)
    #println(detb)
    for i in 1:ndetmain
        copy!(Det{N_int, UInt64}(deepcopy(deta),deepcopy(detb),true), ctxt.detlistmain[i]);
        ctxt.ndetlistmain[i] = ndet;
    end
    ctxt.ndetmain = ndetmain
end

function DMC_fermionic_p(t,U,ET,τ,stepsize,ζ,nruns,nsteps,nwalkermax,nwalkermin,minGrowthRate,norb,nalpha,nadvance,ctxt,to,nthreads,ninitdets, ndimmax,etlist, eprojlist, nwlist)

    # Initial guess
    generateInitialGuess!(norb,nalpha,ninitdets,ctxt)

    # calculate masks
    detI0 = ctxt.detlistmain[1];
    EI0 = hdiag!(detI0, ctxt.bigOne[1].α, norb, U);

    Eproj = EI0
    Eprojold = Eproj

    ndetid = 1
    dictmain = Dict();
    dictmain[hash(detI0)] = 1
    idx = dictmain[hash(detI0)]
    ctxt.ndetlistmain[idx] = ninitdets

    tlst = Dict();

    nwalker = 0
    Nw = 0
    nwalkerold = 0
    Nwold = 0
    ETmean=0.0
    ETold=ET
    nuniquedetmax = 0
    growthRate = 0.0
    progbar = Progress(nsteps; enabled=true, showspeed=true)
    generate_showvalues(iter, x, y, z) = () -> [(:iter,iter), (:Nw,x), (:Nsp,y), (:Nded,z)]
    for irun in 1:nruns
        #println(" ------------------------- ")
        #println(" |   RUN  $irun             |")
        #println(" ------------------------- ")
        #generateInitialGuess!(norb, nalpha, ninitdets, ctxt, ndetmain=nthreads)
        nwalker = 0
        nwalker = sum(ctxt.ndetlistmain[1:ctxt.ndetmain])
        Nw = nwalker
        doStep = false;
        istep = 1
        istepall = 1
        ET=ETold
        nadvance = irun
        while istep <= nsteps && istepall < nsteps

            etlist[irun,istep]=ET

            istep += 1
            istepall += 1

            nuniqdets = ctxt.ndetmain

            if nuniquedetmax < nuniqdets
                nuniquedetmax = nuniqdets
            end

            ndead = launchspawn!(norb, τ, t, U, ET, nadvance, istep, ndimmax, nthreads, tlst, ctxt, to, dictmain);

            #nspawn_branch = mergedetslistall_improv!(ctxt, nthreads, dictmain);
            #nspawn_branch = mergedetslistall!(ctxt, nthreads, dictmain);
            #@timeit to "merge" nspawn_branch = mergedetslistall_improv!(ctxtlist, nthreads, to);

            mergedetslistall_dict!(ctxt, nthreads, to, dictmain)

            nwalkerold = nwalker
            #nwalker = sum(values(dictmain))
            nwalker = sum(ctxt.ndetlistmain[1:ctxt.ndetmain])
            nwlist[irun,istep]=nwalker

            if nwalker > nwalkermin
                doStep = true
                doStepfirst = true
            end

            if istep % stepsize == 0 && doStep
            #if istep % stepsize == 0
                idhf = 1;
                ET = adjustShift(ET,ζ,τ,nwalker,nwalkerold,stepsize);
                ETmean = 0*ETmean + ET;
            end

            #if istep % (stepsize * 10) == 0
            if istep % (stepsize * 1) == 0
            #if true
                Nwold = Nw
                Nw = nwalker
                frac_efficiency = nwalkerold/nwalker
                growthRate = (Nw-Nwold)
                if growthRate > minGrowthRate
                    nwalkermin = nwalker
                end
                #println("Efficiency=",frac_efficiency, " Ndets=",nuniqdets, " GrowthR=",growthRate, " Ndets(max)=",nuniquedetmax)
                ETmean = ETmean / (1);
                #println("istep = ",istep, " Nspawn = ",nwalker-nwalkerold," Ndead=",ndead," Nw = ",Nw," ET = ",ET," EL(",Eproj,") "," ζ= ",ζ," stepsize= ",stepsize," tau= ",τ);
                #println( nwalker_bar, "istep = ",istep, " Nspawn = ",nwalker-nwalkerold," Nw = ",Nw," ET = ",ET," EL(",Eproj,") "," ζ= ",ζ," stepsize= ",stepsize," tau= ",τ )
            end
            #set_description(nwalker_bar, string(@sprintf("IStep: %.2d", istep)))
            nspawn = nwalker-nwalkerold
            next!(progbar; showvalues = [(:iter,istep), (:Nw,nwalker), (:Nsp, nspawn),(:Nded, ndead)])
        end
    end
    return(etlist,eprojlist,nwlist,dictmain)
end
