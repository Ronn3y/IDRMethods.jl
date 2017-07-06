module IDRMethods

export fqmrIDRs

using Base.BLAS
using Base.LinAlg

include("harmenView.jl")

type Identity
end
type Preconditioner
end

type Projector
  j
  mu
  M
  R0
  u
  m

  Projector(n, s, T) = new(0, zero(T), zeros(T, s, s), Matrix{T}(n, s), zeros(T, s), Vector{T}(s))
end

type Hessenberg
  n
  s
  r
  h
  cosine
  sine
  phi
  phihat

  Hessenberg(n, s, T, rho0) = new(n, s, zeros(T, s + 3), zeros(T, s + 2), zeros(T, s + 2), zeros(T, s + 2), zero(T), rho0)
end

type Arnoldi
  A
  P
  permG
  G
  W
  g
  n
  s
  v           # last projected orthogonal to R0
  vhat

  alpha

  # TODO how many n-vectors do we need? (g, v, vhat)
  Arnoldi(A, P, g, n, s, T) = new(A, P, [1 : s...], Matrix{T}(n, s), Matrix{T}(n, s + 1), g, n, s, copy(g), Vector{T}(n), Vector{T}(s))
end

type Solution
  x
  rho
  rho0
  tol

  Solution(x, rho, tol) = new(x, rho, rho, tol)
end


function fqmrIDRs(A, b; s = 8, tol = sqrt(eps(real(eltype(b)))), maxIt = size(b, 1), x0 = zeros(b), P = Identity())

  # TODO skip if x0 = 0
  r0 = b - A * x0
  rho0 = vecnorm(r0)
  hessenberg = Hessenberg(size(b, 1), s, eltype(b), rho0)
  arnoldi = Arnoldi(A, P, r0 / rho0, size(b, 1), s, eltype(b))
  arnoldi.W[:, 1] = 0. # TODO put inside arnoldi constructor
  solution = Solution(x0, rho0, tol)
  projector = Projector(size(b, 1), s, eltype(b))

  iter = 0
  stopped = false

  while !stopped
    for k in 1 : s + 1
      iter += 1

      if iter == s + 1
        initialize!(projector, arnoldi)
      end

      if iter > s
        apply!(projector, arnoldi)
      end

      cycle!(arnoldi)
      cycle!(hessenberg)

      expand!(arnoldi)

      if k == s + 1
        nextIDRSpace!(projector, arnoldi)
      end
      mapToIDRSpace!(arnoldi, projector, k)

      updateG!(arnoldi, hessenberg, k)
      update!(hessenberg, projector, iter)
      updateW!(arnoldi, hessenberg, k, iter)

      update!(solution, arnoldi, hessenberg, projector, k)
      if isConverged(solution) || iter == maxIt
        stopped = true
        break
      end
    end
  end

  return solution.x, solution.rho
end


function apply!(proj::Projector, arnold::Arnoldi)
  gemv!('C', 1.0, proj.R0, arnold.v, 0.0, proj.m)
  lu = lufact(proj.M)
  A_ldiv_B!(proj.u, lu, proj.m)
  gemv!('N', -1.0, arnold.G, proj.u, 1.0, arnold.v)
  proj.u = -view(proj.u, arnold.permG)
  proj.M[:, arnold.permG[1]] = proj.m
end


@inline function initialize!(proj::Projector, arnold::Arnoldi)
  # TODO replace by in-place orth?
  rand!(proj.R0)
  qrfact!(proj.R0)
  gemm!('C', 'N', 1.0, proj.R0, arnold.G, 1.0, proj.M)
end

function nextIDRSpace!(proj::Projector, arnold::Arnoldi)
  proj.j += 1

  # Compute residual minimizing mu
  tv = vecdot(arnold.g, arnold.v)
  tt = vecdot(arnold.g, arnold.g)

  omega = tv / tt
  rho = tv / (sqrt(tt) * norm(arnold.v))
  if abs(rho) < 0.7
    omega *= 0.7 / abs(rho)
  end
  proj.mu = abs(omega) > eps() ? 1. / omega : 1.
end

@inline function cycle!(hes::Hessenberg)
  hes.cosine[1 : end - 1] = unsafe_view(hes.cosine, 2 : hes.s + 2)
  hes.sine[1 : end - 1] = unsafe_view(hes.sine, 2 : hes.s + 2)
end

# Updates the QR factorization of H
function update!(hes::Hessenberg, proj::Projector, iter)
  axpy!(proj.mu, proj.u, unsafe_view(hes.h, 1 : hes.s))
  hes.h[end - 1] += proj.mu
  hes.r[1] = 0.
  hes.r[2 : end] = hes.h

  # Apply previous Givens rotations to new column of h
  for l = max(1, hes.s + 3 - iter) : hes.s + 1
    oldRl = hes.r[l]
    hes.r[l] = hes.cosine[l] * oldRl + hes.sine[l] * hes.r[l + 1]
    hes.r[l + 1] = -conj(hes.sine[l]) * oldRl + hes.cosine[l] * hes.r[l + 1]
  end

  # Compute new Givens rotation
  a = hes.r[end - 1]
  b = hes.r[end]
  if abs(a) < eps()
    hes.sine[end] = 1.
    hes.cosine[end] = 0.
    hes.r[end - 1] = b
  else
    t = abs(a) + abs(b)
    rho = t * sqrt(abs(a / t) ^ 2 + abs(b / t) ^ 2)
    alpha = a / abs(a)

    hes.sine[end] = alpha * conj(b) / rho
    hes.cosine[end] = abs(a) / rho
    hes.r[end - 1] = alpha * rho
  end

  hes.phi = hes.cosine[end] * hes.phihat
  hes.phihat = -conj(hes.sine[end]) * hes.phihat
end

# TODO see if we can include g in G
@inline last(arnold::Arnoldi) = arnold.g

@inline function cycle!(arnold::Arnoldi)
  pGEnd = arnold.permG[1]
  arnold.permG[1 : end - 1] = unsafe_view(arnold.permG, 2 : arnold.s)
  arnold.permG[end] = pGEnd

  arnold.G[:, pGEnd] = arnold.g
end

@inline evalPrecon!(P::Identity, v) =
@inline function evalPrecon!(P::Preconditioner, v)
  v = P \ v
end

@inline function expand!(arnold::Arnoldi)
  copy!(arnold.vhat, arnold.v)
  evalPrecon!(arnold.P, arnold.vhat)
  A_mul_B!(arnold.g, arnold.A, arnold.vhat)
end

function updateW!(arnold::Arnoldi, hes::Hessenberg, k, iter)
  if iter > arnold.s
    # TODO make periodic iterator such that view can be used here on hes.r
    gemv!('N', -1.0, arnold.W, hes.r[[arnold.s + 2 - k : arnold.s + 1; 1 : arnold.s + 1 - k]], 1.0, arnold.vhat)
  else
    gemv!('N', -1.0, unsafe_view(arnold.W, :, 1 : k), hes.r[arnold.s + 2 - k : arnold.s + 1], 1.0, arnold.vhat)
  end
  wIdx = k > arnold.s ? 1 : k + 1
  copy!(unsafe_view(arnold.W, :, wIdx), arnold.vhat)
  scale!(unsafe_view(arnold.W, :, wIdx), 1 / hes.r[end - 1])
end

function updateG!(arnold::Arnoldi, hes::Hessenberg, k)
  # TODO (repeated) CGS?
  hes.h[:] = 0.
  if k < arnold.s + 1
    for l in 1 : k
      arnold.alpha[l] = vecdot(unsafe_view(arnold.G, :, arnold.permG[arnold.s - k + l]), arnold.g)
      axpy!(-arnold.alpha[l], unsafe_view(arnold.G, :, arnold.permG[arnold.s - k + l]), arnold.g)
    end
    hes.h[arnold.s + 2 - k : arnold.s + 1] = unsafe_view(arnold.alpha, 1 : k)
  end
  hes.h[end] = vecnorm(arnold.g)
  scale!(arnold.g, 1 / hes.h[end])
  copy!(arnold.v, arnold.g)

end

@inline function mapToIDRSpace!(arnold::Arnoldi, proj::Projector, k)
  if proj.j > 0
    axpy!(-proj.mu, arnold.v, arnold.g);
  end
end

@inline function isConverged(sol::Solution)
  return sol.rho < sol.tol * sol.rho0
end

function update!(sol::Solution, arnold::Arnoldi, hes::Hessenberg, proj::Projector, k)
  wIdx = k > arnold.s ? 1 : k + 1
  axpy!(hes.phi, unsafe_view(arnold.W, :, wIdx), sol.x)

  sol.rho = abs(hes.phihat) * sqrt(proj.j + 1.)
end

end
