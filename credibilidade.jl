# credibilidade.jl
#
# Bühlmann-Straub em dados reais de fundos brasileiros. O script baixa os
# Informes Diários e o cadastro oficial da CVM, forma retornos mensais de fundos
# Ações Livre e avalia três previsores em janelas fora da amostra:
#   (1) média histórica individual;
#   (2) média do coletivo;
#   (3) prêmio de credibilidade Z·X̄ᵢ + (1-Z)·μ̂.
#
# Os dados brutos ficam em cache local e não são versionados.
# Reproduzir: julia --project=. credibilidade.jl

using Downloads, Printf, Statistics, ZipFile

const CVM_INF_URL = "https://dados.cvm.gov.br/dados/FI/DOC/INF_DIARIO/DADOS"
const CVM_CAD_URL = "https://dados.cvm.gov.br/dados/FI/CAD/DADOS/cad_fi.csv"
const DATA_DIR = get(ENV, "PQ_CVM_DATA", joinpath(@__DIR__, "data", "cvm"))
const FIRST_MONTH = 202101
const LAST_MONTH = 202412
const MIN_TRAIN = 12
const RETURN_FLOOR = -0.50
const RETURN_CEILING = 1.00

"Converte um campo numérico da CVM, preservando `missing` em campos vazios."
function cvmfloat(value::AbstractString)
    isempty(value) && return missing
    parsed = tryparse(Float64, replace(value, ',' => '.'))
    return isnothing(parsed) ? missing : parsed
end

"Divide uma linha dos arquivos da CVM, cujo separador é ponto e vírgula."
fields(line::AbstractString) = split(chomp(line), ';'; keepempty = true)

"Avança um inteiro AAAAMM em um mês."
function nextmonth(yyyymm::Int)
    year, month = divrem(yyyymm, 100)
    month == 12 ? 100 * (year + 1) + 1 : yyyymm + 1
end

"Lista inclusivamente os meses entre dois inteiros AAAAMM."
function monthrange(first::Int, last::Int)
    months = Int[]
    current = first
    while current <= last
        push!(months, current)
        current = nextmonth(current)
    end
    return months
end

"Baixa um arquivo somente quando ele ainda não existe no cache."
function cached_download(url::AbstractString, path::AbstractString)
    isfile(path) && return path
    mkpath(dirname(path))
    partial = path * ".part"
    for attempt in 1:3
        try
            @printf("Baixando %s (tentativa %d/3)\n", basename(path), attempt)
            Downloads.download(url, partial)
            mv(partial, path; force = true)
            return path
        catch error
            attempt == 3 && rethrow(error)
            sleep(2.0 * attempt)
        end
    end
    error("Falha inesperada ao baixar $url")
end

"Seleciona no cadastro fundos Ações Livre, abertos e não exclusivos."
function eligible_funds(cad_path::AbstractString)
    eligible = Set{String}()
    open(cad_path, "r") do io
        header = fields(readline(io))
        index = Dict(name => i for (i, name) in enumerate(header))
        required = ("CNPJ_FUNDO", "DT_CANCEL", "CLASSE", "CONDOM",
                    "FUNDO_EXCLUSIVO", "CLASSE_ANBIMA")
        all(haskey(index, name) for name in required) ||
            error("Cadastro da CVM sem as colunas esperadas")

        for line in eachline(io)
            row = fields(line)
            classe = row[index["CLASSE"]]
            classe_anbima = row[index["CLASSE_ANBIMA"]]
            cancelamento = row[index["DT_CANCEL"]]

            # A comparação por prefixo/sufixo evita depender da codificação
            # Latin-1 dos acentos no arquivo cadastral.
            is_equity = startswith(classe, "A") && ncodeunits(classe) < 10
            is_livre = endswith(classe_anbima, "Livre")
            is_open = row[index["CONDOM"]] == "Aberto"
            is_nonexclusive = row[index["FUNDO_EXCLUSIVO"]] == "N"
            live_through_2024 = isempty(cancelamento) || cancelamento > "2024-12-31"

            if is_equity && is_livre && is_open && is_nonexclusive && live_through_2024
                push!(eligible, row[index["CNPJ_FUNDO"]])
            end
        end
    end
    return eligible
end

"Lê a última cota válida de cada fundo em um arquivo mensal compactado."
function month_end_quotes(zip_path::AbstractString, eligible::Set{String})
    reader = ZipFile.Reader(zip_path)
    try
        length(reader.files) == 1 || error("ZIP inesperado: $zip_path")
        io = reader.files[1]
        # Ler o membro inteiro evita milhares de pequenas chamadas de leitura
        # ao descompressor, que são muito lentas em `eachline(::ZipFile.ReadableFile)`.
        lines = split(read(io, String), '\n'; keepempty = false)
        header = fields(lines[1])
        index = Dict(name => i for (i, name) in enumerate(header))

        # A coluna mudou quando os informes foram adaptados à Resolução CVM 175.
        id_name = haskey(index, "CNPJ_FUNDO") ? "CNPJ_FUNDO" : "CNPJ_FUNDO_CLASSE"
        for name in (id_name, "DT_COMPTC", "VL_QUOTA")
            haskey(index, name) || error("Informe da CVM sem a coluna $name")
        end

        last = Dict{String,Tuple{String,Float64}}()
        for line in @view lines[2:end]
            row = fields(line)
            cnpj = row[index[id_name]]
            cnpj in eligible || continue
            quota = cvmfloat(row[index["VL_QUOTA"]])
            (ismissing(quota) || quota <= 0) && continue
            date = row[index["DT_COMPTC"]]
            if !haskey(last, cnpj) || date >= last[cnpj][1]
                last[cnpj] = (date, quota)
            end
        end
        return Dict(cnpj => value[2] for (cnpj, value) in last)
    finally
        close(reader)
    end
end

"Baixa os arquivos necessários e monta as cotas de fim de mês."
function load_quotes()
    mkpath(DATA_DIR)
    cad_path = cached_download(CVM_CAD_URL, joinpath(DATA_DIR, "cad_fi.csv"))
    eligible = eligible_funds(cad_path)
    quotes = Dict{String,Dict{Int,Float64}}(cnpj => Dict{Int,Float64}()
                                               for cnpj in eligible)

    for yyyymm in monthrange(FIRST_MONTH, LAST_MONTH)
        filename = "inf_diario_fi_$(yyyymm).zip"
        path = cached_download("$CVM_INF_URL/$filename", joinpath(DATA_DIR, filename))
        for (cnpj, quota) in month_end_quotes(path, eligible)
            quotes[cnpj][yyyymm] = quota
        end
        @printf("Processado %d\n", yyyymm)
    end
    filter!(pair -> !isempty(pair.second), quotes)
    return quotes, length(eligible)
end

"Calcula retornos mensais e os centraliza pela média transversal do mês."
function relative_returns(quotes::Dict{String,Dict{Int,Float64}})
    raw = Dict{String,Dict{Int,Float64}}()
    excluded = 0
    for (cnpj, series) in quotes
        months = sort!(collect(keys(series)))
        returns = Dict{Int,Float64}()
        for (previous, current) in zip(months[1:end-1], months[2:end])
            current == nextmonth(previous) || continue
            value = series[current] / series[previous] - 1
            if RETURN_FLOOR <= value <= RETURN_CEILING
                returns[current] = value
            else
                excluded += 1
            end
        end
        raw[cnpj] = returns
    end

    benchmark = Dict{Int,Float64}()
    for month in monthrange(nextmonth(FIRST_MONTH), LAST_MONTH)
        month_values = [series[month] for series in Base.values(raw) if haskey(series, month)]
        isempty(month_values) || (benchmark[month] = mean(month_values))
    end

    relative = Dict{String,Dict{Int,Float64}}()
    for (cnpj, series) in raw
        relative[cnpj] = Dict(month => value - benchmark[month]
                              for (month, value) in series)
    end
    return relative, excluded
end

"Estimadores não paramétricos de Bühlmann-Straub com peso unitário por mês."
function buhlmann_straub(means::Vector{Float64}, variances::Vector{Float64},
                         exposure::Vector{Int})
    funds = length(means)
    total = sum(exposure)
    sigma2 = sum((exposure .- 1) .* variances) / sum(exposure .- 1)
    weighted_mean = sum(exposure .* means) / total
    q = sum(exposure .* (means .- weighted_mean) .^ 2)
    denominator = total - sum(exposure .^ 2) / total
    tau2 = max((q - (funds - 1) * sigma2) / denominator, 0.0)
    if tau2 == 0
        return weighted_mean, sigma2, tau2, zeros(funds)
    end
    kappa = sigma2 / tau2
    credibility = exposure ./ (exposure .+ kappa)
    collective_mean = sum(credibility .* means) / sum(credibility)
    return collective_mean, sigma2, tau2, credibility
end

struct FoldResult
    year::Int
    funds::Int
    exposure::Vector{Int}
    sigma2::Float64
    tau2::Float64
    kappa::Float64
    credibility::Vector{Float64}
    collective_mean::Float64
    raw::Vector{Float64}
    shrunk::Vector{Float64}
    realized::Vector{Float64}
    top_count::Int
    raw_top_estimate::Float64
    raw_top_realized::Float64
    cred_top_estimate::Float64
    cred_top_realized::Float64
end

"Ajusta o modelo antes de um ano e avalia os doze meses seguintes."
function evaluate_fold(relative::Dict{String,Dict{Int,Float64}}, train_end::Int,
                       test_start::Int, test_end::Int)
    ids = String[]
    training = Vector{Float64}[]
    testing = Vector{Float64}[]
    for (cnpj, series) in relative
        train = [value for (month, value) in series if 202102 <= month <= train_end]
        test = [value for (month, value) in series if test_start <= month <= test_end]
        if length(train) >= MIN_TRAIN && length(test) == 12
            push!(ids, cnpj)
            push!(training, train)
            push!(testing, test)
        end
    end

    exposure = length.(training)
    raw = mean.(training)
    variances = var.(training)
    realized = mean.(testing)
    collective_mean, sigma2, tau2, credibility =
        buhlmann_straub(raw, variances, exposure)
    shrunk = credibility .* raw .+ (1 .- credibility) .* collective_mean

    top_count = round(Int, length(ids) * 0.10)
    top_raw = partialsortperm(raw, 1:top_count; rev = true)
    top_cred = partialsortperm(shrunk, 1:top_count; rev = true)
    year = div(test_start, 100)

    return FoldResult(year, length(ids), exposure, sigma2, tau2,
                      tau2 == 0 ? Inf : sigma2 / tau2, credibility,
                      collective_mean, raw, shrunk, realized, top_count,
                      mean(raw[top_raw]), mean(realized[top_raw]),
                      mean(shrunk[top_cred]), mean(realized[top_cred]))
end

mse(estimate, realized) = mean((estimate .- realized) .^ 2)
annual_mean(value) = 1200 * value
annual_vol(value) = 100 * sqrt(12) * value
annual_rmse(value) = 1200 * sqrt(value)

function print_fold(result::FoldResult)
    collective = fill(result.collective_mean, result.funds)
    @printf("\n=== Validação fora da amostra: %d ===\n", result.year)
    @printf("Fundos: %d | histórico: %d–%d meses | mediana: %.0f\n",
            result.funds, minimum(result.exposure), maximum(result.exposure),
            median(result.exposure))
    @printf("σ: %.2f%% a.a. | τ: %.2f%% a.a. | κ: %.1f meses | Z mediano: %.3f\n",
            annual_vol(sqrt(result.sigma2)), annual_mean(sqrt(result.tau2)),
            result.kappa, median(result.credibility))
    @printf("RMSE anualizado — individual: %.2f | coletivo: %.2f | credibilidade: %.2f\n",
            annual_rmse(mse(result.raw, result.realized)),
            annual_rmse(mse(collective, result.realized)),
            annual_rmse(mse(result.shrunk, result.realized)))
    @printf("Top %d por média bruta — estimado: %+.2f | realizado: %+.2f\n",
            result.top_count, annual_mean(result.raw_top_estimate),
            annual_mean(result.raw_top_realized))
    @printf("Top %d por credibilidade — estimado: %+.2f | realizado: %+.2f\n",
            result.top_count, annual_mean(result.cred_top_estimate),
            annual_mean(result.cred_top_realized))
end

function main()
    quotes, eligible = load_quotes()
    relative, excluded = relative_returns(quotes)
    @printf("Cadastro elegível: %d fundos | com cotas no período: %d\n",
            eligible, length(quotes))
    @printf("Retornos fora do intervalo [%.0f%%, %.0f%%] excluídos: %d\n",
            100 * RETURN_FLOOR, 100 * RETURN_CEILING, excluded)

    folds = [
        evaluate_fold(relative, 202212, 202301, 202312),
        evaluate_fold(relative, 202312, 202401, 202412),
    ]
    foreach(print_fold, folds)

    raw_sse = sum(result.funds * mse(result.raw, result.realized) for result in folds)
    collective_sse = sum(result.funds * mse(fill(result.collective_mean, result.funds),
                                            result.realized) for result in folds)
    cred_sse = sum(result.funds * mse(result.shrunk, result.realized) for result in folds)
    observations = sum(result.funds for result in folds)

    println("\n=== Resultado agregado dos dois testes ===")
    @printf("Fundos-ano: %d\n", observations)
    @printf("RMSE anualizado — individual: %.2f | coletivo: %.2f | credibilidade: %.2f\n",
            annual_rmse(raw_sse / observations),
            annual_rmse(collective_sse / observations),
            annual_rmse(cred_sse / observations))
    @printf("Redução de MSE da credibilidade vs. individual: %.1f%%\n",
            100 * (1 - cred_sse / raw_sse))
    @printf("Variação de MSE da credibilidade vs. coletivo: %+.1f%%\n",
            100 * (cred_sse / collective_sse - 1))
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
