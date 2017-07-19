type Identity end
type Preconditioner end

abstract type Projector{T} end
abstract type IDRSpace{T} end

abstract type OrthType end
type ClassicalGS <: OrthType
end
type RepeatedClassicalGS <: OrthType
  one
  tol
  maxRepeat
end
type ModifiedGS <: OrthType
end

abstract type SkewType end
type RepeatSkew <: SkewType
  one
  tol
  maxRepeat
end
type SingleSkew <: SkewType
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

function orthogonalize!{T}(g::StridedVector{T}, G::StridedMatrix{T}, h::StridedVector{T}, orthT::ClassicalGS)
  Ac_mul_B!(h, G, g)
  gemv!('N', -one(T), G, h, one(T), g)

  return norm(g)
end

# Orthogonalize g w.r.t. G, and store coeffs in h (NB g is not normalized)
function orthogonalize!{T}(g::StridedVector{T}, G::StridedMatrix{T}, h::StridedVector{T}, orthT::RepeatedClassicalGS)
  Ac_mul_B!(h, G, g)
  # println(0, ", normG = ", norm(g), ", normH = ", norm(h))
  gemv!('N', -one(T), G, h, one(T), g)

  normG = norm(g)
  normH = norm(h)

  happy = normG < orthT.one * normH || normH < orthT.tol * normG
  # println(1, ", normG = ", normG, ", normH = ", norm(G' * g))
  if happy return normG end

  for idx = 2 : orthT.maxRepeat
    updateH = Vector(h)

    Ac_mul_B!(updateH, G, g)
    gemv!('N', -one(T), G, updateH, one(T), g)

    axpy!(one(T), updateH, h)

    normG = norm(g)
    normH = norm(updateH)
    # println(idx, ", normG = ", normG, ", normH = ", normH)
    happy = normG < orthT.one * normH || normH < orthT.tol * normG
    if happy break end
  end

  return normG
end

function orthogonalize!{T}(g::StridedVector{T}, G::StridedMatrix{T}, h::StridedVector{T}, orthT::ModifiedGS)
  for l in 1 : length(h)
    h[l] = dot(unsafe_view(G, :, l), g)
    axpy!(-h[l], unsafe_view(G, :, l), g)
  end
  return norm(g)
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
function skewProject!{T}(v::StridedVector{T}, G1::StridedMatrix{T}, G2::StridedMatrix{T}, R0::StridedMatrix{T}, lu, α, u, uIdx1, uIdx2, m, skewT::SingleSkew)
  Ac_mul_B!(m, R0, v)
  A_ldiv_B!(α, lu, m)

  copy!(u, α[[uIdx1; uIdx2]])
  gemv!('N', -one(T), G1, unsafe_view(u, 1 : length(uIdx1)), one(T), v)
  gemv!('N', -one(T), G2, unsafe_view(u, length(uIdx1) + 1 : length(u)), one(T), v)
end

function skewProject!{T}(v::StridedVector{T}, G::StridedMatrix{T}, R0::StridedMatrix{T}, lu, α, u, uIdx, m, skewT::SingleSkew)
  Ac_mul_B!(m, R0, v)
  A_ldiv_B!(α, lu, m)

  copy!(u, α[uIdx])
  gemv!('N', -one(T), G, u, one(T), v)
end


# function skewProject!(v, G1, G2, R0, lu, u, idx1, idx2, perm, m, skewT::RepeatSkew)
#   Ac_mul_B!(m, R0, v)
#   A_ldiv_B!(u, lu, m)
#   u[:] = u[perm]
#
#   gemv!('N', -1.0, G1, unsafe_view(u, idx1), 1.0, v)
#   gemv!('N', -1.0, G2, unsafe_view(u, idx2), 1.0, v)
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
#     gemv!('N', -1.0, G1, unsafe_view(uUpdate, idx1), 1.0, v)
#     gemv!('N', -1.0, G2, unsafe_view(uUpdate, idx2), 1.0, v)
#
#     axpy!(1.0, mUpdate, m)
#     axpy!(1.0, uUpdate, u)
#
#     happy = norm(v) > skewT.one * norm(uUpdate)
#     if happy break end
#   end
# end
