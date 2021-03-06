using LinearAlgebra

type Identity end
type Preconditioner end

abstract type Projector{T} end
abstract type IDRSpace{T} end

type OrthType{Method}
  one
  tol
  maxRepeat
end

type SkewType{Method}
  one
  tol
  maxRepeat
end

abstract type Solution{T} end
type NormalSolution{T} <: Solution{T}
  x
  ρ
  rho0
  tol
  r

end
NormalSolution{T}(x::StridedVector{T}, ρ, tol, r0) = NormalSolution{T}(x, [ρ], ρ, tol, r0)

abstract type SmoothedSolution{T} <: Solution{T} end


# With residual smoothing
type QMRSmoothedSolution{T} <: SmoothedSolution{T}
  ρ
  rho0
  tol
  r

  # Residual smoothing as proposed in
  #   Residual Smoothing Techniques for Iterative Methods
  #   Lu Zhou and Homer F. Walker
  # Algorithm 3.2.2
  η
  τ
  x
  s
  u
  v

end
QMRSmoothedSolution{T}(x::StridedVector{T}, ρ, tol, r0) = QMRSmoothedSolution{T}([ρ], ρ, tol, r0, ρ ^ 2, ρ ^ 2, x, copy(r0), zeros(T, size(r0)), zeros(T, size(r0)))

type MRSmoothedSolution{T} <: SmoothedSolution{T}
  ρ
  rho0
  tol
  r

  # Algorithm 2.2
  x
  s
  u
  v

end
MRSmoothedSolution{T}(x::StridedVector{T}, ρ, tol, r0) = MRSmoothedSolution{T}([ρ], ρ, tol, r0, x, copy(r0), zeros(T, size(r0)), zeros(T, size(r0)))


function nextIDRSpace!{T}(proj::Projector, idr::IDRSpace{T})
  proj.j += 1

  # Compute residual minimizing μ
  ν = dot(unsafe_view(idr.G, :, idr.latestIdx), idr.v)
  τ = dot(unsafe_view(idr.G, :, idr.latestIdx), unsafe_view(idr.G, :, idr.latestIdx))

  proj.ω = ν / τ
  η = ν / (sqrt(τ) * norm(idr.v))
  if abs(η) < proj.κ
    proj.ω *= proj.κ / abs(η)
  end
  # TODO condest(A)? instead of 1.
  proj.μ = abs(proj.ω) > eps(real(T)) ? one(T) / proj.ω : one(T)

end

# Orthogonalize g w.r.t. G, and store coeffs in h (NB g is not normalized)
function orthogonalize!{T}(g::StridedVector{T}, G::StridedMatrix{T}, h::StridedVector{T}, orthT::OrthType{:CGS})
  Ac_mul_B!(h, G, g)
  BLAS.gemv!('N', -one(T), G, h, one(T), g)

  return norm(g)
end

function orthogonalize!{T}(g::StridedVector{T}, G::StridedMatrix{T}, h::StridedVector{T}, orthT::OrthType{:MGS})
  for l in 1 : length(h)
    h[l] = dot(unsafe_view(G, :, l), g)
    axpy!(-h[l], unsafe_view(G, :, l), g)
  end
  return norm(g)
end

function rep_orthogonalize!{T}(g::StridedVector{T}, G::StridedMatrix{T}, h::StridedVector{T}, orthT::OrthType)

  normG = orthogonalize!(g, G, h, orthT)
  if orthT.maxRepeat == 1
    return normG
  end

  updateH = copy(h)

  for rep = 2 : orthT.maxRepeat
    normH = norm(updateH)

    if normG < orthT.one * normH || normH < orthT.tol * normG
      break
    end

    normG = orthogonalize!(g, G, updateH, orthT)
    axpy!(one(T), updateH, h)
  end

  return normG
end


@inline function isConverged{T}(sol::Solution{T})
  return sol.ρ[end] < sol.tol * sol.rho0
end

@inline evalPrecon!(vhat, P::Identity, v) = copy!(vhat, v)
@inline function evalPrecon!(vhat, P::Preconditioner, v)
  A_ldiv_B!(vhat, P, v)
end
@inline function evalPrecon!(vhat, P::Function, v)
  P(vhat, v)
end

# To ensure contiguous memory, we often have to split the projections in 2 blocks
function skewProject!{T}(v::StridedVector{T}, G1::StridedMatrix{T}, G2::StridedMatrix{T}, R0::StridedMatrix{T}, lu, α, u, uIdx1, uIdx2, m, skewT::SkewType{false})
  Ac_mul_B!(m, R0, v)
  A_ldiv_B!(α, lu, m)

  copy!(u, α[[uIdx1; uIdx2]])
  BLAS.gemv!('N', -one(T), G1, unsafe_view(u, 1 : length(uIdx1)), one(T), v)
  BLAS.gemv!('N', -one(T), G2, unsafe_view(u, length(uIdx1) + 1 : length(u)), one(T), v)
end

function skewProject!{T}(v::StridedVector{T}, G::StridedMatrix{T}, R0::StridedMatrix{T}, lu, α, u, uIdx, m, skewT::SkewType{false})
  Ac_mul_B!(m, R0, v)
  A_ldiv_B!(α, lu, m)

  copy!(u, α[uIdx])
  BLAS.gemv!('N', -one(T), G, u, one(T), v)
end


# function skewProject!(v, G1, G2, R0, lu, u, idx1, idx2, perm, m, skewT::SkewType{true})
#   Ac_mul_B!(m, R0, v)
#   A_ldiv_B!(u, lu, m)
#   u[:] = u[perm]
#
#   BLAS.gemv!('N', -1.0, G1, unsafe_view(u, idx1), 1.0, v)
#   BLAS.gemv!('N', -1.0, G2, unsafe_view(u, idx2), 1.0, v)
#
#   happy = norm(v) < skewT.one * norm(u)
#
#   if happy return end
#
#   mUpdate = zeros(m)
#   uUpdate = zeros(u)
#   for idx = 2 : skewT.maxRepeat
#     # Repeat projection
#     Ac_mul_B!(mUpdate, R0, v)
#     A_ldiv_B!(uUpdate, lu, mUpdate)
#     uUpdate[:] = uUpdate[perm]
#
#     BLAS.gemv!('N', -1.0, G1, unsafe_view(uUpdate, idx1), 1.0, v)
#     BLAS.gemv!('N', -1.0, G2, unsafe_view(uUpdate, idx2), 1.0, v)
#
#     axpy!(1.0, mUpdate, m)
#     axpy!(1.0, uUpdate, u)
#
#     happy = norm(v) > skewT.one * norm(uUpdate)
#     if happy break end
#   end
# end
