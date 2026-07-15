# pq_credibilidade

Código de apoio ao artigo **"Teoria da credibilidade para quants: o que a atuária já sabia sobre shrinkage"**, da publicação [Pílulas de Quant](https://pilulasdequant.substack.com).

O script simula um painel de 200 fundos com históricos desiguais (1 a 10 anos) e aplica o estimador não-paramétrico de Bühlmann-Straub para estimar o alfa de cada fundo, comparando três estimadores por Monte Carlo: a média amostral individual, a média do coletivo e o prêmio de credibilidade. Também quantifica a maldição do vencedor na seleção dos melhores fundos por média bruta e mostra como o fator de credibilidade Z corrige a seleção.

## Como reproduzir

```bash
julia --project=. -e "using Pkg; Pkg.instantiate()"
julia --project=. credibilidade.jl
```

Requer Julia 1.10+. A simulação usa semente fixa (`MersenneTwister(42)`) e é determinística.

## Referência central

BÜHLMANN, Hans; GISLER, Alois. *A Course in Credibility Theory and its Applications*. Berlim: Springer, 2005.
