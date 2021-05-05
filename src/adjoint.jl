using MacroTools
using MacroTools: @q, combinedef

function named(arg)
  if isexpr(arg, :(::)) && length(arg.args) == 1
    :($(gensym())::$(arg.args[1]))
  elseif isexpr(arg, :kw)
    @assert length(arg.args) == 2
    decl, default = arg.args
    Expr(:kw, named(decl), default)
  else
    arg
  end
end

typeless(x) = MacroTools.postwalk(x -> isexpr(x, :(::), :kw) ? x.args[1] : x, x)
isvararg(x) = isexpr(x, :(::)) && namify(x.args[2]) == :Vararg

for n = 0:3
  gradtuple = Symbol(:gradtuple, n)
  @eval begin
    $gradtuple(x::Tuple) = ($(ntuple(_->:nothing,n)...), x...)
    $gradtuple(x::Nothing) = nothing
    $gradtuple(x) = error("Gradient $x should be a tuple")
  end
end

abstract type AContext end
function adjoint end
function _pullback end
function pullback end

function gradm(ex, mut = false)
  @capture(shortdef(ex), (name_(args__) = body_) |
                         (name_(args__) where {Ts__} = body_)) || error("Need a function definition")
  kw = length(args) > 1 && isexpr(args[1], :parameters) ? esc(popfirst!(args)) : nothing
  isclosure = isexpr(name, :(::)) && length(name.args) > 1
  f, T = isexpr(name, :(::)) ?
    (length(name.args) == 1 ? (esc(gensym()), esc(name.args[1])) : esc.(name.args)) :
    (esc(gensym()), :(Core.Typeof($(esc(name)))))
  kT = :(Core.kwftype($T))
  Ts == nothing && (Ts = [])
  args = named.(args)
  argnames = Any[typeless(arg) for arg in args]
  !isempty(args) && isvararg(args[end]) && (argnames[end] = :($(argnames[end])...,))
  args = esc.(args)
  argnames = esc.(argnames)
  Ts = esc.(Ts)
  cx = :($(esc(:__context__))::AContext)
  fargs = kw == nothing ? [cx, :($f::$T), args...] : [kw, cx, :($f::$T), args...]
  gradtuple   = isclosure ? gradtuple0 : gradtuple1
  gradtuplekw = isclosure ? gradtuple2 : gradtuple3
  adj = @q @inline ZygoteRules.adjoint($(fargs...)) where $(Ts...) = $(esc(body))
  quote
    $adj
    @inline function ZygoteRules._pullback($cx, $f::$T, $(args...)) where $(Ts...)
      argTs = map(typeof, ($(argnames...),))
      y, _back = adjoint(__context__, $f, $(argnames...))
      $(mut ? nothing : :(back(::Nothing) = nothing))
      back(Δ) = $gradtuple(ZygoteRules.clamptype(argTs, _back(Δ)))
      return y, back
    end
    @inline function ZygoteRules._pullback($cx, ::$kT, kw, $f::$T, $(args...)) where $(Ts...)
      argTs = map(typeof, ($(argnames...),))
      y, _back = adjoint(__context__, $f, $(argnames...); kw...)
      $(mut ? nothing : :(back(::Nothing) = nothing))
      back(Δ) = $gradtuplekw(ZygoteRules.clamptype(argTs, _back(Δ)))
      return y, back
    end
    nothing
  end
end

macro adjoint(ex)
  gradm(ex)
end

macro adjoint!(ex)
  gradm(ex, true)
end

clamptype(::Type{<:Real}, dx::Complex) = (@info "preserving Real, from $dx"; real(dx))
clamptype(::Type{<:AbstractArray{<:Real}}, dx::AbstractArray{<:Complex}) = 
  (@info "fixing AbstractArray{<:Complex}"; real(dx))

clamptype(Ts::Tuple{Vararg{<:Type,N}}, dxs::Tuple{Vararg{Any,N}}) where {N} =
    map(clamptype, Ts, dxs)
clamptype(x, dx) = (@debug "Any" x dx; dx)

# Booleans aren't differentiable
clamptype(::Type{Bool}, dx) = (@info "Bool => dropping $dx"; nothing)
clamptype(::Type{Bool}, dx::Complex) = (@info "Bool => dropping $dx"; nothing)  # for ambiguity
clamptype(::Type{<:AbstractArray{<:Bool}}, dx::AbstractArray) = (@info "Bool array => dropping $dx"; nothing)
clamptype(::Type{<:AbstractArray{<:Bool}}, dx::AbstractArray{<:Complex}) = (@info "Bool array => dropping complex $dx"; nothing)

import LinearAlgebra
# Matrix wrappers
for ST in [:Diagonal, :Symmetric, :Hermitian, :UpperTriangular, :LowerTriangular]
  str = string("preserving ", ST)
  @eval begin
    clamptype(::Type{<:LinearAlgebra.$ST}, dx::LinearAlgebra.$ST) = dx
    clamptype(::Type{<:LinearAlgebra.$ST}, dx::AbstractMatrix) = (@info $str; LinearAlgebra.$ST(dx))
    # these won't yet compose with complex to real, should call on parent somehow?
  end
end
# Vector wrappers
clamptype(T::Type{<:LinearAlgebra.Adjoint{<:Number, <:AbstractVector}}, dx::LinearAlgebra.AdjOrTransAbsVec) = dx
clamptype(T::Type{<:LinearAlgebra.Adjoint{<:Number, <:AbstractVector}}, dx::AbstractMatrix) =
  if eltype(dx) <: Real
    @info "preserving Adjoint"
    Base.adjoint(vec(dx))
  else
    @info "Adjoint -> Transpose"
    transpose(vec(dx))
  end
clamptype(T::Type{<:LinearAlgebra.Transpose{<:Number, <:AbstractVector}}, dx::LinearAlgebra.AdjOrTransAbsVec) = dx
clamptype(T::Type{<:LinearAlgebra.Transpose{<:Number, <:AbstractVector}}, dx::AbstractMatrix) = 
  (@info "preserving Transpose"; transpose(vec(dx)))

#=

using Zygote, LinearAlgebra

using ZygoteRules
ENV["JULIA_DEBUG"] = "all"

gradient(x -> abs2(x+im), 0.2)     # was (0.4 + 2.0im,)
gradient(x -> abs2(x+im), 0.2+0im) # old & new agree

gradient(sqrt, true)
gradient(x -> sum(sqrt, x), rand(3) .> 0.5)

gradient(x -> sum(sqrt.(x .+ 10)), Diagonal(rand(3)))[1]

sy1 = gradient(x -> sum(x .+ 1), Symmetric(ones(3,3)))[1] # tries but fails
sy2 = gradient(x -> sum(x * x'), Symmetric(ones(3,3)))[1] # tries but fails

ud = gradient((x,y) -> sum(x * y), UpperTriangular(ones(3,3)), Diagonal(ones(3,3)));
ud[1] # works, UpperTriangular
ud[2] # fails to preserve Diagonal

@eval Zygote begin  # crudely apply this also to ChainRules rules:
  using ZygoteRules: clamptype
  @inline function chain_rrule(f, args...)
    y, back = rrule(f, args...)
    ctype = (Nothing, map(typeof, args)...)
    return y, (b -> clamptype(ctype, b))∘ZBack(back)
  end

# now ud[2] works, sy still fails.

Zygote.pullback(x -> x.+1, rand(3)')[2](ones(1,3))[1]
Zygote.pullback(x -> x.+1, rand(ComplexF64, 3)')[2](ones(1,3))[1]
Zygote.pullback(x -> x.+1, rand(ComplexF64, 3)')[2](fill(0+im, 1,3))[1]

=#
