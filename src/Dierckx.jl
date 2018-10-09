__precompile__()

module Dierckx

export Spline1D,
       Spline2D,
       ParametricSpline,
       evaluate,
       evaluate!,
       derivative,
       derivative!,
       integrate,
       roots,
       evalgrid,
       get_knots,
       get_coeffs,
       get_residual

import Base: show


const depsfile = joinpath(dirname(dirname(@__FILE__)),"deps","deps.jl")
if isfile(depsfile)
    include(depsfile)
else
    error("Dierckx is not properly installed. Please run Pkg.build(\"Dierckx\")")
end

function __init__()
    check_deps()
end

# ----------------------------------------------------------------------------
# 1-d splines

const _fit1d_messages = Dict(
2=>
"""A theoretically impossible result was found during the iteration
process for finding a smoothing spline with fp = s: s too small.
There is an approximation returned but the corresponding weighted sum
of squared residuals does not satisfy the condition abs(fp-s)/s <
tol.""",
3=>
"""The maximal number of iterations maxit (set to 20 by the program)
allowed for finding a smoothing spline with fp=s has been reached: s
too small. There is an approximation returned but the corresponding
weighted sum of squared residuals does not satisfy the condition
abs(fp-s)/s < tol.""",
10=>
"""Error on entry, no approximation returned. The following conditions
must hold:
1<=k<=5
x[1] < x[2] < ... < x[end]
w[i] > 0.0 for all i

Additionally, if spline knots are given:
length(xknots) <= length(x) + k + 1
x[1] < xknots[1] < xknots[k+2] < ... < xknots[end] < x[end]
The schoenberg-whitney conditions: there must be a subset of data points
xx[j] such that t[j] < xx[j] < t[j+k+1] for j=1,2,...,n-k-1""")


const _eval1d_messages = Dict(
1=>
"""Input point out of range""",
10=>
"""Invalid input data. The following conditions must hold:
length(x) != 0 and xb <= x[1] <= x[2] <= ... x[end] <= xe""")

_translate_bc(bc::AbstractString) = (bc == "extrapolate" ? 0 :
                             bc == "zero" ? 1 :
                             bc == "error" ? 2 :
                             bc == "nearest" ? 3 :
                             error("unknown boundary condition: \"$bc\""))
_translate_bc(bc::Int) = (bc == 0 ? "extrapolate" :
                          bc == 1 ? "zero" :
                          bc == 2 ? "error" :
                          bc == 3 ? "nearest" : "")

mutable struct Spline1D
    t::Vector{Float64}
    c::Vector{Float64}
    k::Int
    bc::Int
    fp::Float64
    wrk::Vector{Float64}
end

# add a constructor that automatically creates the `work` array
Spline1D(t, c, k, bc, fp) = Spline1D(t, c, k, bc, fp, Vector{Float64}(undef, length(t)))

get_knots(spl::Spline1D) = spl.t[spl.k+1:end-spl.k]
get_coeffs(spl::Spline1D) = spl.c[1:end-spl.k+1]
get_residual(spl::Spline1D) = spl.fp
showcompact(io::IO, x) = show(IOContext(io, :compact => true), x)
readstring(io::IO) = read(io, String)

function reallycompact(a::Vector)
    io = IOBuffer()
    if length(a) <= 5
        show(io, a)
    else
        write(io, "[")
        showcompact(io, a[1])
        write(io, ",")
        showcompact(io, a[2])
        write(io, " \u2026 ")
        showcompact(io, a[end-1])
        write(io, ",")
        showcompact(io, a[end])
        write(io, "]")
        write(io, " ($(length(a)) elements)")
    end
    seekstart(io)
    readstring(io)
end


function show(io::IO, spl::Spline1D)
    print(io, """Spline1D(knots=$(reallycompact(get_knots(spl))), k=$(spl.k), extrapolation=\"$(_translate_bc(spl.bc))\", residual=$(spl.fp))""")
end

function Spline1D(x::AbstractVector, y::AbstractVector;
                  w::AbstractVector=ones(length(x)),
                  k::Int=3, s::Real=0.0, bc::AbstractString="nearest",
                  periodic::Bool=false)
    m = length(x)
    length(y) == m || error("length of x and y must match")
    length(w) == m || error("length of x and w must match")
    m > k || error("k must be less than length(x)")
    1 <= k <= 5 || error("1 <= k = $k <= 5 must hold")

    # ensure inputs are of correct type
    xin = convert(Vector{Float64}, x)
    yin = convert(Vector{Float64}, y)
    win = convert(Vector{Float64}, w)

    nest = 0
    if periodic
        nest = max(m + 2k, 2k + 3)
    else
        nest = max(m + k + 1, 2k + 3)
    end

    # outputs
    n = Ref{Int32}(0)
    t = Vector{Float64}(undef, nest)
    c = Vector{Float64}(undef, nest)
    fp = Ref{Float64}(0)
    ier = Ref{Int32}(0)

    # workspace
    lwrk = 0
    if periodic
        lwrk = m * (k + 1) + nest*(8 + 5k)
    else
        lwrk = m * (k + 1) + nest*(7 + 3k)
    end
    wrk = Vector{Float64}(undef, lwrk)
    iwrk = Vector{Int32}(undef, nest)

    if !periodic
        ccall((:curfit_, libddierckx), Nothing,
            (Ref{Int32}, Ref{Int32},  # iopt, m
             Ref{Float64}, Ref{Float64}, Ref{Float64},  # x, y, w
             Ref{Float64}, Ref{Float64},  # xb, xe
             Ref{Int32}, Ref{Float64},  # k, s
             Ref{Int32}, Ref{Int32}, # nest, n
             Ref{Float64}, Ref{Float64}, Ref{Float64},  # t, c, fp
             Ref{Float64}, Ref{Int32}, Ref{Int32},  # wrk, lwrk, iwrk
             Ref{Int32}),  # ier
            0, m, xin, yin, win, xin[1], xin[end], k, Float64(s),
            nest, n, t, c, fp, wrk, lwrk, iwrk, ier)
    else
        ccall((:percur_, libddierckx), Nothing,
            (Ref{Int32}, Ref{Int32}, # iopt, m
             Ref{Float64}, Ref{Float64}, Ref{Float64}, # x, y, w
             Ref{Int32}, Ref{Float64}, # k, s
             Ref{Int32}, Ref{Int32}, # nest, n
             Ref{Float64}, Ref{Float64}, Ref{Float64}, # t, c, fp
             Ref{Float64}, Ref{Int32}, Ref{Int32}, # wrk, lwrk, iwrk
             Ref{Int32}), # ier
            0, m, xin, yin, win, k, Float64(s), nest, n, t, c,
            fp, wrk, lwrk, iwrk, ier)
    end

    ier[] <= 0 || error(_fit1d_messages[ier[]])

    # resize output arrays
    resize!(t, n[])
    resize!(c, n[] - k - 1)

    return Spline1D(t, c, k, _translate_bc(bc), fp[])
end

# version with user-supplied knots
function Spline1D(x::AbstractVector, y::AbstractVector,
                  knots::AbstractVector;
                  w::AbstractVector=ones(length(x)),
                  k::Int=3, bc::AbstractString="nearest",
                  periodic::Bool=false)
    m = length(x)
    length(y) == m || error("length of x and y must match")
    length(w) == m || error("length of x and w must match")
    m > k || error("k must be less than length(x)")
    length(knots) <= m + k + 1 || error("length(knots) <= length(x) + k + 1 must hold")
    first(x) < first(knots) || error("first(x) < first(knots) must hold")
    last(x) > last(knots) || error("last(x) > last(knots) must hold")

    # ensure inputs are of correct type
    xin = convert(Vector{Float64}, x)
    yin = convert(Vector{Float64}, y)
    win = convert(Vector{Float64}, w)

    # x knots
    # (k+1) knots will be added on either end of interior knots.
    n = length(knots) + 2(k + 1)
    t = Vector{Float64}(undef, n)  # All knots
    t[k+2:end-k-1] = knots

    # outputs
    c = Vector{Float64}(undef, n)
    fp = Ref{Float64}(0)
    ier = Ref{Int32}(0)

    # workspace
    lwrk = 0
    if periodic
        lwrk = m * (k + 1) + n*(8 + 5k)
    else
        lwrk = m * (k + 1) + n*(7 + 3k)
    end
    wrk = Vector{Float64}(undef, lwrk)
    iwrk = Vector{Int32}(undef, n)

    if !periodic
        ccall((:curfit_, libddierckx), Nothing,
            (Ref{Int32}, Ref{Int32},  # iopt, m
             Ref{Float64}, Ref{Float64}, Ref{Float64},  # x, y, w
             Ref{Float64}, Ref{Float64},  # xb, xe
             Ref{Int32}, Ref{Float64},  # k, s
             Ref{Int32}, Ref{Int32}, # nest, n
             Ref{Float64}, Ref{Float64}, Ref{Float64},  # t, c, fp
             Ref{Float64}, Ref{Int32}, Ref{Int32},  # wrk, lwrk, iwrk
             Ref{Int32}),  # ier
            -1, m, xin, yin, win, xin[1], xin[end], k, -1.0,
            n, n, t, c, fp, wrk, lwrk, iwrk, ier)
    else
        ccall((:percur_, libddierckx), Nothing,
            (Ref{Int32}, Ref{Int32}, # iopt, m
             Ref{Float64}, Ref{Float64}, Ref{Float64}, # x, y, w
             Ref{Int32}, Ref{Float64}, # k, s
             Ref{Int32}, Ref{Int32}, # nest, n
             Ref{Float64}, Ref{Float64}, Ref{Float64}, # t, c, fp
             Ref{Float64}, Ref{Int32}, Ref{Int32}, # wrk, lwrk, iwrk
             Ref{Int32}), # ier
            -1, m, xin, yin, win, k, -1.0, n, n, t, c,
            fp, wrk, lwrk, iwrk, ier)
    end

    ier[] <= 0 || error(_fit1d_messages[ier[]])
    resize!(c, n - k - 1)

    return Spline1D(t, c, k, _translate_bc(bc), fp[])
end


function _evaluate(t::Vector{Float64}, c::Vector{Float64}, k::Int,
                   x::Vector{Float64}, bc::Int)
    bc in (0, 1, 2, 3) || error("bc = $bc not in (0, 1, 2, 3)")
    m = length(x)
    xin = convert(Vector{Float64}, x)
    y = Vector{Float64}(undef, m)
    ier = Ref{Int32}(0)
    ccall((:splev_, libddierckx), Nothing,
         (Ref{Float64}, Ref{Int32},
          Ref{Float64}, Ref{Int32},
          Ref{Float64}, Ref{Float64}, Ref{Int32},
          Ref{Int32}, Ref{Int32}),
         t, length(t), c, k, xin, y, m, bc, ier)

    ier[] == 0 || error(_eval1d_messages[ier[]])
    return y
end

function _evaluate(t::Vector{Float64}, c::Vector{Float64}, k::Int,
                   x::Real, bc::Int)
    bc in (0, 1, 2, 3) || error("bc = $bc not in (0, 1, 2, 3)")
    y = Ref{Float64}(0)
    ier = Ref{Int32}(0)
    ccall((:splev_, libddierckx), Nothing,
         (Ref{Float64}, Ref{Int32},
          Ref{Float64}, Ref{Int32},
          Ref{Float64}, Ref{Float64}, Ref{Int32},
          Ref{Int32}, Ref{Int32}),
         t, length(t), c, k, Float64(x), y, 1, bc, ier)

    ier[] == 0 || error(_eval1d_messages[ier[]])
    return y[]
end


evaluate(spline::Spline1D, x::AbstractVector) =
    _evaluate(spline.t, spline.c, spline.k,
              convert(Vector{Float64}, x), spline.bc)


evaluate(spline::Spline1D, x::Real) =
    _evaluate(spline.t, spline.c, spline.k, x, spline.bc)


function _derivative(t::Vector{Float64}, c::Vector{Float64}, k::Int,
                     x::Vector{Float64}, nu::Int, bc::Int, wrk::Vector{Float64})
    (1 <= nu <= k) || error("order of derivative must be positive and less than or equal to spline order")
    m = length(x)
    n = length(t)
    y = Vector{Float64}(undef, m)
    ier = Ref{Int32}(0)
    ccall((:splder_, libddierckx), Nothing,
         (Ref{Float64}, Ref{Int32}, # t, n
          Ref{Float64}, Ref{Int32}, # c, k
          Ref{Int32}, # nu
          Ref{Float64}, Ref{Float64}, Ref{Int32}, # x, y, m
          Ref{Int32}, Ref{Float64}, Ref{Int32}), # e, wrk, ier
         t, n, c, k, nu, x, y, m, bc, wrk, ier)
    ier[] == 0 || error(_eval1d_messages[ier[]])
    return y
end

function _derivative(t::Vector{Float64}, c::Vector{Float64}, k::Int,
                     x::Real, nu::Int, bc::Int, wrk::Vector{Float64})
    (1 <= nu <= k) || error("order of derivative must be positive and less than or equal to spline order")
    n = length(t)
    y = Ref{Float64}(0)
    ier = Ref{Int32}(0)
    ccall((:splder_, libddierckx), Nothing,
         (Ref{Float64}, Ref{Int32}, # t, n
          Ref{Float64}, Ref{Int32}, # c, k
          Ref{Int32}, # nu
          Ref{Float64}, Ref{Float64}, Ref{Int32}, # x, y, m
          Ref{Int32}, Ref{Float64}, Ref{Int32}), # e, wrk, ier
         t, n, c, k, nu, Float64(x), y, 1, bc, wrk, ier)
    ier[] == 0 || error(_eval1d_messages[ier[]])
    return y[]
end

# TODO: should the function name be evalder, derivative, or grad?
#       or should it be integrated with evaluate, above?
#       (problem with that: derivative doesn't accept bc="nearest")
# TODO: should `nu` be `d`?
derivative(spline::Spline1D, x::AbstractVector, nu::Int=1) =
    _derivative(spline.t, spline.c, spline.k,
                convert(Vector{Float64}, x), nu, spline.bc, spline.wrk)


derivative(spline::Spline1D, x::Real, nu::Int=1) =
    _derivative(spline.t, spline.c, spline.k, x, nu, spline.bc, spline.wrk)


# TODO: deprecate this?
derivative(spline::Spline1D, x; nu::Int=1) = derivative(spline, x, nu)


function _integrate(t::Vector{Float64}, c::Vector{Float64}, k::Int,
                    a::Real, b::Real, wrk::Vector{Float64})
    n = length(t)
    ccall((:splint_, libddierckx), Float64,
        (Ref{Float64}, Ref{Int32},
         Ref{Float64}, Ref{Int32},
         Ref{Float64}, Ref{Float64},
         Ref{Float64}),
         t, n, c, k,
         Float64(a), Float64(b), wrk)
end

integrate(spline::Spline1D, a::Real, b::Real) =
    _integrate(spline.t, spline.c, spline.k, a, b, spline.wrk)

# TODO roots for parametric splines
# note: default maxn in scipy.interpolate is 3 * (length(spline.t) - 7)
function roots(spline::Spline1D; maxn::Integer=8)
    if spline.k != 3
        error("root finding only supported for cubic splines (k=3)")
    end
    n = length(spline.t)
    zeros = Vector{Float64}(undef, maxn)
    m = Vector{Int32}(undef, 1)
    ier = Vector{Int32}(undef, 1)
    ccall((:sproot_, libddierckx), Nothing,
          (Ref{Float64}, Ref{Int32},  # t, n
           Ref{Float64}, Ref{Float64},  # c, zeros
           Ref{Int32}, Ref{Int32},  # mest, m
           Ref{Int32}),  # ier
          spline.t, n, spline.c, zeros,
          maxn, m, ier)

    if ier[1] == 0
        return zeros[1:m[1]]
    elseif ier[1] == 1
        warn("number of zeros exceeded maxn; only first maxn zeros returned")
        return zeros
    elseif ier[1] == 10
        error("Invalid input data.")
    else
        error("unknown error code in sproot: $(ier[1])")
    end
end

# ----------------------------------------------------------------------------
# parametric splines

mutable struct ParametricSpline
    t::Vector{Float64}
    c::Vector{Float64}
    k::Int
    bc::Int
    fp::Float64
    wrk::Vector{Float64}
    idim::Int
    n::Int
end

ParametricSpline(t, c, k, bc, fp, idim, n) =
    ParametricSpline(t, c, k, bc, fp, Vector{Float64}(undef, length(c)), idim, n)

get_knots(spl::ParametricSpline) = spl.t[spl.k+1:spl.n-spl.k]
get_coeffs(spl::ParametricSpline) =
    [spl.c[spl.n*(j-1) + i] for j=1:spl.idim, i=1:spl.n-2*spl.k]
get_residual(spl::ParametricSpline) = spl.fp

function show(io::IO, spl::ParametricSpline)
    print(io, """ParametricSpline(knots=$(reallycompact(get_knots(spl))), k=$(spl.k), extrapolation=\"$(_translate_bc(spl.bc))\", residual=$(spl.fp))""")
end

function ParametricSpline(x::AbstractMatrix;
                          w::AbstractVector=ones(size(x, 2)),
                          k::Int=3, s::Real=0.0, bc::AbstractString="nearest",
                          periodic::Bool=false)
    return _ParametricSpline(nothing, x, nothing, w, k, s, bc, periodic)
end

# version with user-supplied u
function ParametricSpline(u::AbstractVector, x::AbstractMatrix;
                          ub::Real=u[1], ue::Real=u[end],
                          w::AbstractVector=ones(size(x, 2)),
                          k::Int=3, s::Real=0.0, bc::AbstractString="nearest",
                          periodic::Bool=false)
    return _ParametricSpline(u, x, nothing, w, k, s, bc, periodic)
end

# version with user-supplied knots
function ParametricSpline(x::AbstractMatrix, knots::AbstractVector;
                          w::AbstractVector=ones(size(x, 2)),
                          k::Int=3, bc::AbstractString="nearest",
                          periodic::Bool=false)
    return _ParametricSpline(nothing, x, knots, w, k, -1.0, bc, periodic)
end

# version with user-supplied u and knots
function ParametricSpline(u::AbstractVector, x::AbstractMatrix,
                          knots::AbstractVector;
                          w::AbstractVector=ones(size(x, 2)),
                          k::Int=3, bc::AbstractString="nearest",
                          periodic::Bool=false)
    return _ParametricSpline(u, x, knots, w, k, -1.0, bc, periodic)
end

function _ParametricSpline(u::Union{AbstractVector, Nothing}, x::AbstractMatrix,
                           knots::Union{AbstractVector, Nothing},
                           w::AbstractVector, k::Int, s::Real,
                           bc::AbstractString, periodic::Bool)
    idim, m = size(x)
    if periodic
        x[:, 1] == x[:, end] || error("for periodic splines x[:,1] and x[:,end] must match")
    end

    length(w) == m || error("number of data points and length of w must match")
    0 < idim < 11 || error("number of dimension must be between 1 and 10")
    m > k || error("number of data points muct be greater than k")
    1 <= k <= 5 || error("1 <= k = $k <= 5 must hold")

    local ipar, uin, ub, ue
    if u != nothing
        all(u[1:end-1] .< u[2:end]) || error("u[i] must be strictly increasing")
        ipar = 1
        uin = convert(Vector{Float64}, u)
        ub = uin[1]
        ue = uin[end]
    else
        ipar = 0
        uin = Vector{Float64}(undef, size(x, 2))
        ub = 0.0
        ue = 1.0
    end

    local iopt, nest::Int, t
    if knots != nothing
        length(knots) <= m + k + 1 || error("length(knots) <= length(x) + k + 1 must hold")
        first(x) < first(knots) || error("first(x) < first(knots) must hold")
        last(x) > last(knots) || error("last(x) > last(knots) must hold")
        iopt = -1
        nest = length(knots) + 2(k + 1)
        t = Vector{Float64}(undef, nest)
        t[k+2:end-k-1] = knots
    else
        iopt = 0
        nest = m + 2k
        if s == 0
            nest = periodic ? m + 2k : m + k + 1
        end
        nest = max(nest, 2k + 3)
        t = Vector{Float64}(undef, nest)
    end

    xin = convert(Matrix{Float64}, x)
    win = convert(Vector{Float64}, w)
    n = Ref{Int32}(nest)
    c = Vector{Float64}(undef, idim*nest)
    fp = Ref{Float64}(0)
    ier = Ref{Int32}(0)

    local lwrk::Int
    if periodic
        lwrk = m*(k + 1) + nest*(7 + idim + 5k)
    else
        lwrk = m*(k + 1) + nest*(6 + idim + 3k)
    end
    wrk = Vector{Float64}(undef, lwrk)
    iwrk = Vector{Int32}(undef, nest)

    if !periodic
        ccall((:parcur_, libddierckx), Nothing,
              (Ref{Int32}, Ref{Int32}, # iopt, ipar
              Ref{Int32}, Ref{Int32}, # idim, m
              Ref{Float64}, Ref{Int32}, # u, mx
              Ref{Float64}, Ref{Float64}, # x, w
              Ref{Float64}, Ref{Float64}, # ub, ue
              Ref{Int32}, Ref{Float64}, # k, s
              Ref{Int32}, Ref{Int32}, # nest, n
              Ref{Float64}, Ref{Int32}, # t, nc
              Ref{Float64}, Ref{Float64}, # c, fp
              Ref{Float64}, Ref{Int32}, # wrk, lwrk
              Ref{Int32}, Ref{Int32}), #iwrk, ier
              iopt, ipar,
              idim, m,
              uin, length(x),
              xin, win,
              ub, ue,
              k, s,
              nest, n,
              t, length(c),
              c, fp,
              wrk, lwrk,
              iwrk, ier)
    else
        ccall((:clocur_, libddierckx), Nothing,
              (Ref{Int32}, Ref{Int32}, # iopt, ipar
              Ref{Int32}, Ref{Int32}, # idim, m
              Ref{Float64}, Ref{Int32}, # u, mx
              Ref{Float64}, Ref{Float64}, # x, w
              Ref{Int32}, Ref{Float64}, # k, s
              Ref{Int32}, Ref{Int32}, # nest, n
              Ref{Float64}, Ref{Int32}, # t, nc
              Ref{Float64}, Ref{Float64}, # c, fp
              Ref{Float64}, Ref{Int32}, # wrk, lwrk
              Ref{Int32}, Ref{Int32}), #iwrk, ier
              iopt, ipar,
              idim, m,
              uin, length(x),
              xin, win,
              k, s,
              nest, n,
              t, length(c),
              c, fp,
              wrk, lwrk,
              iwrk, ier)
    end

    ier[] <= 0 || error(_fit1d_messages[ier[]])

    resize!(t, n[])
    c = [c[n[]*(j-1) + i] for j=1:idim, i=1:n[]-k-1]

    return ParametricSpline(t, c, k, _translate_bc(bc), fp[], idim, n[])
end

function _evaluate!(x::Matrix{Float64}, t::Vector{Float64}, c::Vector{Float64},
                    k::Int, u::Vector{Float64}, bc::Int, idim::Int, n::Int)
    bc in (0, 1, 2, 3) || error("bc = $bc not in (0, 1, 2, 3)")
    m = length(u)
    size(x, 1) == idim && size(x, 2) == m || error("x must be of size ($idim, $m)")
    ier = Ref{Int32}(0)
    ccall((:curev_, libddierckx), Nothing,
         (Ref{Int32}, Ref{Float64},
          Ref{Int32}, Ref{Float64},
          Ref{Int32}, Ref{Int32},
          Ref{Float64}, Ref{Int32},
          Ref{Float64}, Ref{Int32},
          Ref{Int32}, Ref{Int32}),
         idim, t, n, c, length(c), k, u, m, x, length(x), bc, ier)

    ier[] == 0 || error(_eval1d_messages[ier[]])
    return x
end

function _evaluate!(x::Vector{Float64}, t::Vector{Float64}, c::Vector{Float64},
                    k::Int, u::Real, bc::Int, idim::Int, n::Int)
    bc in (0, 1, 2, 3) || error("bc = $bc not in (0, 1, 2, 3)")
    length(x) == idim || error("x must be of length $idim")
    ier = Ref{Int32}(0)
    ccall((:curev_, libddierckx), Nothing,
         (Ref{Int32}, Ref{Float64},
          Ref{Int32}, Ref{Float64},
          Ref{Int32}, Ref{Int32},
          Ref{Float64}, Ref{Int32},
          Ref{Float64}, Ref{Int32},
          Ref{Int32}, Ref{Int32}),
         idim, t, n, c, length(c), k, Float64(u), 1, x, length(x), bc, ier)

    ier[] == 0 || error(_eval1d_messages[ier[]])
    return x
end

evaluate!(x::Matrix{Float64}, spline::ParametricSpline, u::AbstractVector) =
    _evaluate!(x, spline.t, spline.c, spline.k, convert(Vector{Float64}, u), spline.bc, spline.idim, spline.n)

evaluate!(x::Vector{Float64}, spline::ParametricSpline, u::Real) =
    _evaluate!(x, spline.t, spline.c, spline.k, u, spline.bc, spline.idim, spline.n)

evaluate(spline::ParametricSpline, u::AbstractVector) =
    evaluate!(Matrix{Float64}(undef, spline.idim, length(u)), spline, u)

evaluate(spline::ParametricSpline, u::Real) =
    evaluate!(Vector{Float64}(undef, spline.idim), spline, u)

function _derivative!(x::Matrix{Float64}, t::Vector{Float64}, c::Vector{Float64},
                      k::Int, u::Vector{Float64}, bc::Int, idim::Int, n::Int,
                      nu::Int, wrk::Vector{Float64})
    bc in (0, 1, 2, 3) || error("bc = $bc not in (0, 1, 2, 3)")
    (1 <= nu <= k) || error("order of derivative must be positive and less than or equal to spline order")
    m = length(u)
    size(x, 1) == idim && size(x, 2) == m || error("x must be of size ($idim, $m)")
    ier = Ref{Int32}(0)
    ccall((:curder_, libddierckx), Nothing,
         (Ref{Int32}, Ref{Float64},
          Ref{Int32}, Ref{Float64},
          Ref{Int32}, Ref{Int32},
          Ref{Int32}, Ref{Float64},
          Ref{Int32}, Ref{Float64},
          Ref{Int32}, Ref{Int32},
          Ref{Float64}, Ref{Int32}),
         idim, t, n, c, length(c), k, nu, u, m, x, length(x), bc, wrk, ier)

    ier[] == 0 || error(_eval1d_messages[ier[]])
    return x
end

function _derivative!(x::Vector{Float64}, t::Vector{Float64}, c::Vector{Float64},
                      k::Int, u::Real, bc::Int, idim::Int, n::Int, nu::Int,
                      wrk::Vector{Float64})
    bc in (0, 1, 2, 3) || error("bc = $bc not in (0, 1, 2, 3)")
    (1 <= nu <= k) || error("order of derivative must be positive and less than or equal to spline order")
    length(x) == idim || error("x must be of length $idim")
    ier = Ref{Int32}(0)
    ccall((:curder_, libddierckx), Nothing,
         (Ref{Int32}, Ref{Float64},
          Ref{Int32}, Ref{Float64},
          Ref{Int32}, Ref{Int32},
          Ref{Int32}, Ref{Float64},
          Ref{Int32}, Ref{Float64},
          Ref{Int32}, Ref{Int32},
          Ref{Float64}, Ref{Int32}),
         idim, t, n, c, length(c), k, nu, Float64(u), 1, x, length(x), bc, wrk, ier)

    ier[] == 0 || error(_eval1d_messages[ier[]])
    return x
end

derivative!(x::Matrix{Float64}, spline::ParametricSpline, u::AbstractVector, nu::Int=1) =
    _derivative!(x, spline.t, spline.c, spline.k, convert(Vector{Float64}, u), spline.bc, spline.idim, spline.n, nu, spline.wrk)

derivative!(x::Vector{Float64}, spline::ParametricSpline, u::Real, nu::Int=1) =
    _derivative!(x, spline.t, spline.c, spline.k, u, spline.bc, spline.idim, spline.n, nu, spline.wrk)

derivative(spline::ParametricSpline, u::AbstractVector, nu::Int=1) =
    derivative!(Matrix{Float64}(undef, spline.idim, length(u)), spline, u, nu)

derivative(spline::ParametricSpline, u::Real, nu::Int=1) =
    derivative!(Vector{Float64}(undef, spline.idim), spline, u, nu)

# TODO: deprecate this
derivative(spline::ParametricSpline, x; nu::Int=1) = derivative(spline, x, nu)

_integrate(t::Vector{Float64}, c::Matrix{Float64}, k::Int,
           a::Real, b::Real, wrk::Vector{Float64}) =
    vec(mapslices(v -> _integrate(t, v, k, a, b, wrk), c, dims=[2]))

integrate(spline::ParametricSpline, a::Real, b::Real) =
    _integrate(spline.t, spline.c, spline.k, a, b, spline.wrk)

# ----------------------------------------------------------------------------
# 2-d splines

# NOTE REGARDING ARGUMENT ORDER: In the "grid" version of the Spline2D
# constructor and evaluators, the fortran functions expects z to have
# shape (my, mx), but we'd rather have x be the fast axis in z.  So,
# in the ccall()s in these methods, all the x and y related inputs are
# swapped with regard to what the Fortran documentation says.

const _fit2d_messages = Dict(
-3=>

"""The coefficients of the spline returned have been computed as the
minimal norm least-squares solution of a (numerically) rank deficient
system (deficiency=%i). If deficiency is large, the results may be
inaccurate. Deficiency may strongly depend on the value of eps.""",

1=>

"""The required storage space exceeds the available storage space:
nxest or nyest too small, or s too small. Try increasing s.""",
# The weighted least-squares spline corresponds to the current set of knots.

2=>

"""A theoretically impossible result was found during the iteration
process for finding a smoothing spline with fp = s: s too small or
badly chosen eps.  Weighted sum of squared residuals does not satisfy
abs(fp-s)/s < tol.""",

3=>

"""the maximal number of iterations maxit (set to 20 by the program)
allowed for finding a smoothing spline with fp=s has been reached: s
too small.  Weighted sum of squared residuals does not satisfy
abs(fp-s)/s < tol.""",

4=>

"""No more knots can be added because the number of b-spline
coefficients (nx-kx-1)*(ny-ky-1) already exceeds the number of data
points m: either s or m too small.  The weighted least-squares spline
corresponds to the current set of knots.""",

5=>

"""No more knots can be added because the additional knot would
(quasi) coincide with an old one: s too small or too large a weight to
an inaccurate data point.  The weighted least-squares spline
corresponds to the current set of knots.""",

10=>

"""Error on entry, no approximation returned. The following conditions
must hold:
xb<=x[i]<=xe, yb<=y[i]<=ye, w[i]>0, i=0..m-1
If iopt==-1, then
  xb<tx[kx+1]<tx[kx+2]<...<tx[nx-kx-2]<xe
  yb<ty[ky+1]<ty[ky+2]<...<ty[ny-ky-2]<ye""")

const _eval2d_message = (
"""Invalid input data. Restrictions:
length(x) != 0, length(y) != 0
x[i-1] <= x[i] for i=2,...,length(x)
y[j-1] <= y[j] for j=2,...,length(y)
""")

mutable struct Spline2D
    tx::Vector{Float64}
    ty::Vector{Float64}
    c::Vector{Float64}
    kx::Int
    ky::Int
    fp::Float64
end

get_knots(spl::Spline2D) = (spl.tx[spl.kx+1:end-spl.kx],
                            spl.ty[spl.ky+1:end-spl.ky])
get_residual(spl::Spline2D) = spl.fp


# Helper functions for calculating required size of work arrays in surfit.
# Note that x and y here are as in the Fortran documentation.
# These are translated from scipy/interpolate/src/fitpack.pyf
function calc_surfit_lwrk1(m, kx, ky, nxest, nyest)
    u = nxest - kx - 1
    v = nyest - ky - 1
    km = max(kx, ky) + 1
    ne = max(nxest, nyest)
    bx = kx*v + ky + 1
    by = ky*u + kx + 1
    b1 = b2 = 0
    if (bx<=by)
        b1 = bx
        b2 = bx + v - ky
    else
        b1 = by
        b2 = by + u - kx
    end
    return u*v*(2 + b1 + b2) + 2*(u+v+km*(m+ne)+ne-kx-ky) + b2 + 1
end

function calc_surfit_lwrk2(m, kx, ky, nxest, nyest)
    u = nxest - kx - 1
    v = nyest - ky - 1
    bx = kx * v + ky + 1
    by = ky * u + kx + 1
    b2 = (bx <= by ? bx + v - ky : by + u - kx)
    return u * v * (b2 + 1) + b2
end

# Construct spline from unstructured data
function Spline2D(x::AbstractVector, y::AbstractVector, z::AbstractVector;
                  w::AbstractVector=ones(length(x)), kx::Int=3, ky::Int=3,
                  s::Real=0.0)

    # array sizes
    m = length(x)
    (length(y) == length(z) == m) || error("lengths of x, y, z must match")
    (length(w) == m) || error("length of w must match other inputs")

    nxest = max(kx+1+ceil(Int,sqrt(m/2)), 2*(kx+1))
    nyest = max(ky+1+ceil(Int,sqrt(m/2)), 2*(ky+1))
    nmax = max(nxest, nyest)

    eps = 1.0e-16

    # bounds
    xb = minimum(x)
    xe = maximum(x)
    yb = minimum(y)
    ye = maximum(y)

    # ensure arrays are of correct type
    xin = convert(Vector{Float64}, x)
    yin = convert(Vector{Float64}, y)
    zin = convert(Vector{Float64}, z)
    win = convert(Vector{Float64}, w)

    # return values
    nx = Ref{Int32}()
    tx = Vector{Float64}(undef, nxest)
    ny = Ref{Int32}()
    ty = Vector{Float64}(undef, nyest)
    c = Vector{Float64}(undef, (nxest-kx-1) * (nyest-ky-1))
    fp = Ref{Float64}()
    ier = Ref{Int32}()

    # work arrays
    # Note: in lwrk1 and lwrk2, x and y are swapped on purpose.
    lwrk1 = calc_surfit_lwrk1(m, ky, kx, nyest, nxest)
    lwrk2 = calc_surfit_lwrk2(m, ky, kx, nyest, nxest)
    kwrk = m + (nxest - 2*kx - 1) * (nyest - 2*ky - 1)
    wrk1 = Vector{Float64}(undef, lwrk1)
    wrk2 = Vector{Float64}(undef, lwrk2)
    iwrk = Vector{Int32}(undef, kwrk)

    ccall((:surfit_, libddierckx), Nothing,
          (Ref{Int32}, Ref{Int32},  # iopt, m
           Ref{Float64}, Ref{Float64},  # y, x
           Ref{Float64}, Ref{Float64},  # z, w
           Ref{Float64}, Ref{Float64},  # yb, ye
           Ref{Float64}, Ref{Float64},  # xb, xe
           Ref{Int32}, Ref{Int32}, Ref{Float64},  # ky, kx, s
           Ref{Int32}, Ref{Int32}, Ref{Int32},  # nyest, nxest, nmax
           Ref{Float64},  # eps
           Ref{Int32}, Ref{Float64},  # ny, tx
           Ref{Int32}, Ref{Float64},  # nx, tx
           Ref{Float64}, Ref{Float64},  # c, fp
           Ref{Float64}, Ref{Int32},  # wrk1, lwrk1
           Ref{Float64}, Ref{Int32},  # wrk2, lwrk2
           Ref{Int32}, Ref{Int32}, Ref{Int32}),   # iwrk, kwrk, ier
          0, m, yin, xin, zin, win, yb, ye, xb, xe, ky, kx,
          Float64(s), nyest, nxest, nmax, eps, ny, ty, nx, tx,
          c, fp, wrk1, lwrk1, wrk2, lwrk2, iwrk, kwrk, ier)

    while ier[] > 10
        # lwrk2 is too small, i.e., there is not enough workspace
        # for computing the minimal least-squares solution of a rank
        # deficient system of linear equations. ier gives the
        # requested value for lwrk2. Rerun with that value in "continue"
        # mode, with iopt = 1.
        lwrk2 = ier[]
        resize!(wrk2, lwrk2)
        ccall((:surfit_, libddierckx), Nothing,
              (Ref{Int32}, Ref{Int32},  # iopt, m
               Ref{Float64}, Ref{Float64},  # y, x
               Ref{Float64}, Ref{Float64},  # z, w
               Ref{Float64}, Ref{Float64},  # yb, ye
               Ref{Float64}, Ref{Float64},  # xb, xe
               Ref{Int32}, Ref{Int32}, Ref{Float64},  # ky, kx, s
               Ref{Int32}, Ref{Int32}, Ref{Int32},  # nyest, nxest, nmax
               Ref{Float64},  # eps
               Ref{Int32}, Ref{Float64},  # ny, tx
               Ref{Int32}, Ref{Float64},  # nx, tx
               Ref{Float64}, Ref{Float64},  # c, fp
               Ref{Float64}, Ref{Int32},  # wrk1, lwrk1
               Ref{Float64}, Ref{Int32},  # wrk2, lwrk2
               Ref{Int32}, Ref{Int32}, Ref{Int32}),   # iwrk, kwrk, ier
              1, m, yin, xin, zin, win, yb, ye, xb, xe, ky, kx, s,
              nyest, nxest, nmax, eps, ny, ty, nx, tx, c, fp,
              wrk1, lwrk1, wrk2, lwrk2, iwrk, kwrk, ier)
    end

    if (ier[] == 0 || ier[] == -1 || ier[] == -2)
        # good values, pass.
    elseif ier[] < -2
        warn("""
        The coefficients of the spline returned have been
        computed as the minimal norm least-squares solution of a
        (numerically) rank deficient system. The rank is $(-ier[]).
        The rank deficiency is $((nx[]-kx-1)*(ny[]-ky-1)+ier[]).
        Especially if the rank deficiency is large the results may
        be inaccurate.""")
        # "The results could also seriously depend on the value of
        # eps" (not in message because eps is currently not an input)
    else
        error(_fit2d_messages[ier[]])
    end

    # Resize output arrays to the size actually used.
    resize!(tx, nx[])
    resize!(ty, ny[])
    resize!(c, (nx[] - kx - 1) * (ny[] - ky - 1))

    return Spline2D(tx, ty, c, kx, ky, fp[])
end



# Construct spline from data on a grid.
function Spline2D(x::AbstractVector, y::AbstractVector, z::AbstractMatrix;
                  kx::Int=3, ky::Int=3, s::Real=0.0)
    mx = length(x)
    my = length(y)
    @assert size(z, 1) == mx && size(z, 2) == my

    mx > kx || error("length(x) must be greater than kx")
    my > ky || error("length(y) must be greater than ky")

    # Bounds
    xb = x[1]
    xe = x[end]
    yb = y[1]
    ye = y[end]
    nxest = mx+kx+1
    nyest = my+ky+1

    # ensure arrays are of correct type
    xin = convert(Vector{Float64}, x)
    yin = convert(Vector{Float64}, y)
    zin = convert(Matrix{Float64}, z)

    # Return values
    nx = Ref{Int32}()
    tx = Vector{Float64}(undef, nxest)
    ny = Ref{Int32}()
    ty = Vector{Float64}(undef, nyest)
    c = Vector{Float64}(undef, (nxest-kx-1) * (nyest-ky-1))
    fp = Ref{Float64}()
    ier = Ref{Int32}()

    # Work arrays.
    # Note that in lwrk, x and y are swapped with respect to the Fortran
    # documentation. See "NOTE REGARDING ARGUMENT ORDER" above.
    lwrk = (4 + nyest * (mx+2*ky+5) + nxest * (2*kx+5) +
            my*(ky+1) + mx*(kx+1) + max(mx, nyest))
    wrk = Vector{Float64}(undef, lwrk)
    kwrk = 3 + mx + my + nxest + nyest
    iwrk = Vector{Int32}(undef, kwrk)

    ccall((:regrid_, libddierckx), Nothing,
          (Ref{Int32},  # iopt
           Ref{Int32}, Ref{Float64},  # my, y
           Ref{Int32}, Ref{Float64},  # mx, x
           Ref{Float64},  # z
           Ref{Float64}, Ref{Float64},  # yb, ye
           Ref{Float64}, Ref{Float64},  # xb, xe
           Ref{Int32}, Ref{Int32}, Ref{Float64},  # ky, kx, s
           Ref{Int32}, Ref{Int32},  # nyest, nxest
           Ref{Int32}, Ref{Float64},  # ny, ty
           Ref{Int32}, Ref{Float64},  # nx, tx
           Ref{Float64}, Ref{Float64},  # c, fp
           Ref{Float64}, Ref{Int32},  # wrk, lwrk
           Ref{Int32}, Ref{Int32},  # iwrk, lwrk
           Ref{Int32}),  # ier
          0f0, my, yin, mx, xin, zin, yb, ye, xb, xe, ky, kx,
          Float64(s), nyest, nxest, ny, ty, nx, tx, c, fp,
          wrk, lwrk, iwrk, kwrk, ier)

    if !(ier[] == 0 || ier[] == -1 || ier[] == -2)
        error(_fit2d_messages[ier[]])
    end

    # Resize output arrays to the size actually used.
    resize!(tx, nx[])
    resize!(ty, ny[])
    resize!(c, (nx[] - kx - 1) * (ny[] - ky - 1))

    return Spline2D(tx, ty, c, kx, ky, fp[])
end


# Evaluate spline at individual points
function evaluate(spline::Spline2D, x::AbstractVector, y::AbstractVector)
    m = length(x)
    @assert length(y) == m

    xin = convert(Vector{Float64}, x)
    yin = convert(Vector{Float64}, y)

    ier = Ref{Int32}()
    lwrk = spline.kx + spline.ky + 2
    wrk = Vector{Float64}(undef, lwrk)
    z = Vector{Float64}(undef, m)

    ccall((:bispeu_, libddierckx), Nothing,
          (Ref{Float64}, Ref{Int32},  # ty, ny
           Ref{Float64}, Ref{Int32},  # tx, nx
           Ref{Float64},  # c
           Ref{Int32}, Ref{Int32},  # ky, kx
           Ref{Float64}, Ref{Float64}, Ref{Float64},  # y, x, z
           Ref{Int32},  # m
           Ref{Float64}, Ref{Int32}, Ref{Int32}),  # wrk, lwrk, ier
          spline.ty, length(spline.ty),
          spline.tx, length(spline.tx),
          spline.c, spline.ky, spline.kx, yin, xin, z, m,
          wrk, lwrk, ier)

    ier[] == 0 || error(_eval2d_message)

    return z
end

function evaluate(spline::Spline2D, x::Real, y::Real)
    ier = Ref{Int32}()
    lwrk = spline.kx + spline.ky + 2
    wrk = Vector{Float64}(undef, lwrk)
    z = Ref{Float64}()
    ccall((:bispeu_, libddierckx), Nothing,
          (Ref{Float64}, Ref{Int32},  # ty, ny
           Ref{Float64}, Ref{Int32},  # tx, nx
           Ref{Float64},  # c
           Ref{Int32}, Ref{Int32},  # ky, kx
           Ref{Float64}, Ref{Float64}, Ref{Float64},  # y, x, z
           Ref{Int32},  # m
           Ref{Float64}, Ref{Int32}, Ref{Int32}),  # wrk, lwrk, ier
          spline.ty, length(spline.ty),
          spline.tx, length(spline.tx),
          spline.c, spline.ky, spline.kx, y, x, z, 1,
          wrk, lwrk, ier)

    ier[] == 0 || error(_eval2d_message)
    return z[]
end

# Evaluate spline on the grid spanned by the input arrays.
function evalgrid(spline::Spline2D, x::AbstractVector, y::AbstractVector)
    mx = length(x)
    my = length(y)

    xin = convert(Vector{Float64}, x)
    yin = convert(Vector{Float64}, y)

    lwrk = mx*(spline.kx + 1) + my*(spline.ky + 1)
    wrk = Vector{Float64}(undef, lwrk)
    kwrk = mx + my
    iwrk = Vector{Int32}(undef, kwrk)
    ier = Ref{Int32}()
    z = Matrix{Float64}(undef, mx, my)

    ccall((:bispev_, libddierckx), Nothing,
          (Ref{Float64}, Ref{Int32},  # ty, ny
           Ref{Float64}, Ref{Int32},  # tx, nx
           Ref{Float64},  # c
           Ref{Int32}, Ref{Int32},  # ky, kx
           Ref{Float64}, Ref{Int32},  # y, my
           Ref{Float64}, Ref{Int32},  # x, mx
           Ref{Float64},  # z
           Ref{Float64}, Ref{Int32},  # wrk, lwrk
           Ref{Int32}, Ref{Int32},  # iwrk, kwrk
           Ref{Int32}),  # ier
          spline.ty, length(spline.ty),
          spline.tx, length(spline.tx),
          spline.c, spline.ky, spline.kx, yin, my, xin, mx, z,
          wrk, lwrk, iwrk, kwrk, ier)

    ier[] == 0 || error(_eval2d_message)

    return z
end

# 2D integration
function integrate(spline::Spline2D, xb::Real, xe::Real, yb::Real, ye::Real)
        nx = length(spline.tx)
        ny = length(spline.ty)

        kx = spline.kx
        ky = spline.ky

        wrk = Vector{Float64}(undef, nx + ny -kx - ky -2)
        ccall((:dblint_, libddierckx), Float64,
              (Ref{Float64}, Ref{Int32},  # tx, nx
               Ref{Float64}, Ref{Int32},  # ty, ny
               Ref{Float64}, Ref{Int32},  # c, kx
               Ref{Int32}, #ky
               Ref{Float64}, Ref{Float64},  # xb, xe
               Ref{Float64}, Ref{Float64},  # yb, ye
               Ref{Float64}),  # wrk
              spline.tx, nx,
              spline.ty, ny,
              spline.c, spline.kx,
              spline.ky,
              xb, xe,
              yb, ye,
              wrk)
end

# call synonyms for evaluate():
(spl::Spline1D)(x::Real) = evaluate(spl, x)
(spl::Spline1D)(x::AbstractVector) = evaluate(spl, x)
(spl::ParametricSpline)(x::Real) = evaluate(spl, x)
(spl::ParametricSpline)(x::AbstractVector) = evaluate(spl, x)
(spl::Spline2D)(x::Real, y::Real) = evaluate(spl, x, y)
(spl::Spline2D)(x::AbstractVector, y::AbstractVector) =
    evaluate(spl, x, y)

end # module
