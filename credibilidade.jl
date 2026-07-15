# credibilidade.jl
# Estimador de Bühlmann-Straub aplicado a um painel de fundos com históricos desiguais.
# Compara três estimadores do alfa mensal de cada fundo:
#   (1) média amostral individual;
#   (2) média do coletivo;
#   (3) prêmio de credibilidade Z·X̄ᵢ + (1−Z)·μ̂.
# Avalia erro quadrático contra o alfa verdadeiro via Monte Carlo e mede a
# maldição do vencedor na seleção dos melhores fundos por média bruta.
#
# Reproduzir: julia --project=. credibilidade.jl

using Random, Statistics, Distributions, Printf

# ---------------------------------------------------------------------------
# Parâmetros do universo simulado (escala mensal)
# ---------------------------------------------------------------------------
const K      = 200        # número de fundos no coletivo
const μ_TRUE = 0.0        # alfa médio do coletivo
const τ_TRUE = 0.00125    # desvio-padrão do alfa entre fundos (≈ 1,5% a.a.)
const σ_TRUE = 0.02       # vol idiossincrática mensal (≈ 6,9% a.a.)
const N_MIN, N_MAX = 12, 120   # históricos entre 1 e 10 anos
const R      = 500        # replicações Monte Carlo
const TOP    = 20         # tamanho da carteira "melhores fundos"

"""
    buhlmann_straub(X̄, S², n)

Estimadores não-paramétricos de Bühlmann-Straub com pesos unitários por mês.
Recebe médias individuais `X̄`, variâncias amostrais `S²` e tamanhos `n`;
devolve (μ̂, σ̂², τ̂², Z), onde Z é o vetor de fatores de credibilidade.
"""
function buhlmann_straub(X̄::Vector{Float64}, S²::Vector{Float64}, n::Vector{Int})
    Kf = length(X̄)
    N  = sum(n)
    # variância intra (within): média ponderada das variâncias amostrais
    σ² = sum((n .- 1) .* S²) / sum(n .- 1)
    # variância entre (between): estimador de Bühlmann-Straub, truncado em zero
    X̄w = sum(n .* X̄) / N
    q  = sum(n .* (X̄ .- X̄w) .^ 2)
    τ² = max((q - (Kf - 1) * σ²) / (N - sum(n .^ 2) / N), 0.0)
    if τ² == 0.0
        Z = zeros(Kf)
        return X̄w, σ², τ², Z
    end
    κ = σ² / τ²
    Z = n ./ (n .+ κ)
    # média do coletivo ponderada por credibilidade (estimador recomendado)
    μ̂ = sum(Z .* X̄) / sum(Z)
    return μ̂, σ², τ², Z
end

"""
    simula_painel(rng)

Sorteia alfas verdadeiros θᵢ ~ N(μ, τ²), históricos nᵢ e retornos mensais
Xᵢₜ ~ N(θᵢ, σ²); devolve (θ, n, X̄, S²).
"""
function simula_painel(rng::AbstractRNG)
    n  = rand(rng, N_MIN:N_MAX, K)
    θ  = rand(rng, Normal(μ_TRUE, τ_TRUE), K)
    X̄  = Vector{Float64}(undef, K)
    S² = Vector{Float64}(undef, K)
    for i in 1:K
        x = rand(rng, Normal(θ[i], σ_TRUE), n[i])
        X̄[i]  = mean(x)
        S²[i] = var(x)
    end
    return θ, n, X̄, S²
end

# ---------------------------------------------------------------------------
# Monte Carlo
# ---------------------------------------------------------------------------
function main()
    rng = MersenneTwister(42)

    mse_ind, mse_col, mse_cred = 0.0, 0.0, 0.0
    est_raw_top, true_raw_top  = 0.0, 0.0   # top-N por média bruta
    est_crd_top, true_crd_top  = 0.0, 0.0   # top-N por credibilidade
    σ̂_acc, τ̂_acc, Z̄_acc = 0.0, 0.0, 0.0
    κ̂s = Float64[]
    horizontes = (12, 36, 60, 120)
    Ẑm_acc = Dict(m => 0.0 for m in horizontes)

    for _ in 1:R
        θ, n, X̄, S² = simula_painel(rng)
        μ̂, σ², τ², Z = buhlmann_straub(X̄, S², n)
        θ̂ = Z .* X̄ .+ (1 .- Z) .* μ̂

        mse_ind  += mean((X̄ .- θ) .^ 2)
        mse_col  += mean((μ̂ .- θ) .^ 2)
        mse_cred += mean((θ̂ .- θ) .^ 2)

        top_raw = partialsortperm(X̄, 1:TOP; rev = true)
        top_crd = partialsortperm(θ̂, 1:TOP; rev = true)
        est_raw_top  += mean(X̄[top_raw]);  true_raw_top += mean(θ[top_raw])
        est_crd_top  += mean(θ̂[top_crd]);  true_crd_top += mean(θ[top_crd])

        σ̂_acc += sqrt(σ²); τ̂_acc += sqrt(τ²); Z̄_acc += mean(Z)
        κ̂ = σ² / τ²   # Inf quando τ̂² trunca em zero
        push!(κ̂s, κ̂)
        for m in horizontes
            Ẑm_acc[m] += m / (m + κ̂)
        end
    end

    mse_ind /= R; mse_col /= R; mse_cred /= R
    est_raw_top /= R; true_raw_top /= R
    est_crd_top /= R; true_crd_top /= R
    σ̂ = σ̂_acc / R; τ̂ = τ̂_acc / R; Z̄ = Z̄_acc / R
    κ̂_med = median(κ̂s)
    trunc_pct = 100 * count(isinf, κ̂s) / R

    aa(x)  = 12 * 100 * x          # alfa mensal → % a.a.
    vol(x) = sqrt(12) * 100 * x    # vol mensal → % a.a.
    κ_true = σ_TRUE^2 / τ_TRUE^2

    println("=== Parâmetros estruturais (verdadeiro vs. estimado, média de $R replicações) ===")
    @printf("σ (vol idiossincrática): %.2f%% a.a. | estimado %.2f%% a.a.\n", vol(σ_TRUE), vol(σ̂))
    @printf("τ (dispersão de alfas):  %.2f%% a.a. | estimado %.2f%% a.a.\n", aa(τ_TRUE), aa(τ̂))
    @printf("κ = σ²/τ²: %.0f meses | mediana estimada %.0f meses | Z médio do painel: %.3f\n",
            κ_true, κ̂_med, Z̄)
    @printf("Replicações com τ̂² truncado em zero (Z = 0): %.1f%%\n", trunc_pct)
    for m in horizontes
        @printf("  Z(n = %3d meses) = %.3f | estimado %.3f\n",
                m, m / (m + κ_true), Ẑm_acc[m] / R)
    end

    println("\n=== Erro de estimação do alfa (RMSE, % a.a.) ===")
    @printf("Média individual:        %.2f\n", aa(sqrt(mse_ind)))
    @printf("Média do coletivo:       %.2f\n", aa(sqrt(mse_col)))
    @printf("Prêmio de credibilidade: %.2f\n", aa(sqrt(mse_cred)))
    @printf("Redução de MSE vs. individual: %.1f%%\n", 100 * (1 - mse_cred / mse_ind))
    @printf("Redução de MSE vs. coletivo:   %.1f%%\n", 100 * (1 - mse_cred / mse_col))

    println("\n=== Maldição do vencedor: top $TOP de $K fundos (alfa % a.a.) ===")
    @printf("Ranking por média bruta:   estimado %+.2f | verdadeiro %+.2f\n",
            aa(est_raw_top), aa(true_raw_top))
    @printf("Ranking por credibilidade: estimado %+.2f | verdadeiro %+.2f\n",
            aa(est_crd_top), aa(true_crd_top))
end

main()
