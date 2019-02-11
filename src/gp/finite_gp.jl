import Base: rand, length
import Distributions: logpdf, ContinuousMultivariateDistribution

export mean, cov, marginals, rand, logpdf, elbo

"""
    FiniteGP{Tf, Tx}

The finite-dimensional projection of the GP `f` at `x`.
"""
struct FiniteGP{Tf<:AbstractGP, Tx<:AV, Tσ²<:AV} <: ContinuousMultivariateDistribution
    f::Tf
    x::Tx 
    σ²::Tσ²
    function FiniteGP(f::AbstractGP, x::AV, σ²::AV{<:Real})
        return new{typeof(f), typeof(x), typeof(σ²)}(f, x, σ²)
    end
end
FiniteGP(f::AbstractGP, x::AV, σ²::Real) = FiniteGP(f, x, Fill(σ², length(x)))

length(f::FiniteGP) = length(f.x)

"""
    mean(f::FiniteGP)

The mean vector of `f`.
"""
mean(f::FiniteGP) = map(mean(f.f), f.x)

"""
    cov(f::FiniteGP)

The covariance matrix of `f`.
"""
cov(f::FiniteGP) = pairwise(kernel(f.f), f.x) + Diagonal(f.σ²)

"""
    cov(f::FiniteGP, g::FiniteGP)

The cross-covariance between `f` and `g`.
"""
cov(f::FiniteGP, g::FiniteGP) = pairwise(kernel(f.f, g.f), f.x, g.x)

"""
    marginals(f::FiniteGP)

Sugar, returns a vector of Normal distributions representing the marginals of `f`.
"""
marginals(f::FiniteGP) = Normal.(mean(f), sqrt.(map(kernel(f.f), f.x) .+ f.σ²))

"""
    rand(rng::AbstractRNG, f::FiniteGP, N::Int=1)

Obtain `N` independent samples from the GP `f` using `rng`.
"""
function rand(rng::AbstractRNG, f::FiniteGP, N::Int)
    μ, C = mean(f), cholesky(cov(f))
    return μ .+ C.U' * randn(rng, length(μ), N)
end
rand(rng::AbstractRNG, f::FiniteGP) = vec(rand(rng, f, 1))
rand(f::FiniteGP, N::Int) = rand(Random.GLOBAL_RNG, f, N)
rand(f::FiniteGP) = vec(rand(f, 1))

"""
    logpdf(f::FiniteGP, y::AbstractVector{<:Real})

The log probability density of `y` under `f`.
"""
function logpdf(f::FiniteGP, y::AbstractVector{<:Real})
    μ, C = mean(f), cholesky(cov(f))
    return -(length(y) * log(2π) + logdet(C) + Xt_invA_X(C, y - μ)) / 2
end

"""
    elbo(f::FiniteGP, y::AbstractVector{<:Real}, u::FiniteGP)

The saturated Titsias-ELBO. 
"""
function elbo(f::FiniteGP, y::AV{<:Real}, u::FiniteGP)
    @assert length(f) == length(y)
    @assert f.σ² isa Fill
    σ² = f.σ²[1]
    Γ = (cholesky(cov(u)).U' \ cov(u, f)) ./ sqrt(σ²)
    Ω, δ = cholesky(Symmetric(Γ * Γ' + I)), y - mean(f)
    # return -(length(y) * log(2π * σ²)) / 2
    # # return -(length(y) * log(2π * σ²) + logdet(Ω) - sum(abs2, Γ)) / 2

    return -(length(y) * log(2π * σ²) + logdet(Ω) - sum(abs2, Γ) +
        (sum(abs2, δ) - sum(abs2, Ω.U' \ (Γ * δ)) + sum(map(kernel(f.f), f.x))) / σ²) / 2
end


####################################################
# `logpdf` and `rand` for collections of processes #
####################################################

# function rand(rng::AbstractRNG, f::BlockGP, N::Int)
#     M = BlockArray(undef_blocks, AbstractMatrix{Float64}, length.(f.fs), [N])
#     μ = mean(f)
#     for b in eachindex(f.fs)
#         setblock!(M, getblock(μ, b) * ones(1, N), b, 1)
#     end
#     return M + chol(cov(f))' * BlockMatrix(randn.(Ref(rng), length.(f.fs), N))
# end
# rand(f::BlockGP, N::Int) = rand(Random.GLOBAL_RNG, f, N)

# function rand(rng::AbstractRNG, f::BlockGP)
#     return mean(f) + chol(cov(f))' * BlockVector(randn.(Ref(rng), length.(f.fs)))
# end
# rand(f::BlockGP) = rand(Random.GLOBAL_RNG, f)

# # Convenience methods for invoking `logpdf` and `rand` with multiple processes.
# logpdf(fs::AV{<:AbstractGP}, ys::AV{<:AV{<:Real}}) = logpdf(BlockGP(fs), BlockVector(ys))

function finites_to_block(fs::AV{<:FiniteGP})
    return FiniteGP(
        BlockGP(map(f->f.f, fs)),
        BlockData(map(f->f.x, fs)),
        vcat(map(f->f.σ², fs)...),
    )
end

function rand(rng::AbstractRNG, fs::AV{<:FiniteGP}, N::Int)
    Y = rand(rng, finites_to_block(fs), N)
    sz = cumsum(map(length, fs))
    return [Y[sz[n]-length(fs[n])+1:sz[n], :] for n in eachindex(fs)]
end
rand(rng::AbstractRNG, fs::AV{<:FiniteGP}) = vec.(rand(rng, fs, 1))
rand(fs::AV{<:FiniteGP}, N::Int) = rand(Random.GLOBAL_RNG, fs, N)
rand(fs::AV{<:FiniteGP}) = vec.(rand(Random.GLOBAL_RNG, fs))

logpdf(fs::AV{<:FiniteGP}, ys::AV{<:AV{<:Real}}) = logpdf(finites_to_block(fs), vcat(ys...))
