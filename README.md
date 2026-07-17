# pq_credibilidade

Código de apoio ao artigo **“Teoria da credibilidade para quants: o que a atuária já sabia sobre shrinkage”**, da publicação [Pílulas de Quant](https://pilulasdequant.substack.com).

O script aplica o estimador não paramétrico de Bühlmann-Straub a dados reais de fundos brasileiros. Ele baixa os [Informes Diários](https://dados.cvm.gov.br/dataset/fi-doc-inf_diario) e o [registro de fundos e classes](https://dados.cvm.gov.br/dataset/fi-cad) da CVM, seleciona classes Ações Livre abertas e não exclusivas, e calcula retornos mensais relativos à média transversal do universo.

A avaliação é fora da amostra. O modelo usa o histórico disponível antes de 2023, 2024 e 2025 para comparar três previsores do retorno relativo médio nos doze meses seguintes:

1. média histórica individual;
2. média do coletivo;
3. prêmio de credibilidade.

## Como reproduzir

```bash
julia --project=. -e "using Pkg; Pkg.instantiate()"
julia --project=. credibilidade.jl
```

Na primeira execução, o script requer acesso à internet e aproximadamente 650 MB para os 60 arquivos mensais da CVM referentes a 2021–2025. Os arquivos são armazenados em `data/cvm`; execuções seguintes reutilizam esse cache. Para usar outro diretório, defina a variável de ambiente `PQ_CVM_DATA`.

O script usa `registro_fundo_classe.zip`, normaliza os CNPJs e trata explicitamente a mudança de `CNPJ_FUNDO` para `CNPJ_FUNDO_CLASSE` ocorrida nos informes de dezembro de 2023, durante a adaptação à Resolução CVM 175. O cadastro legado `cad_fi.csv` não é usado para filtrar 2025 porque registra como cancelados vários veículos migrados para a estrutura de classes.

## Fonte e limitações

Os dados de cota, patrimônio e cotistas são reportados pelos fundos à CVM. O recorte exige doze meses completos na janela de teste e, portanto, contém viés de sobrevivência. A classificação vem do registro consultado depois dos primeiros anos da amostra e pode refletir alterações cadastrais posteriores. O retorno relativo à média transversal não é alfa de regressão. A validação mede previsão da média realizada no ano seguinte; não revela um parâmetro “verdadeiro” não observável.

## Referência central

BÜHLMANN, Hans; GISLER, Alois. *A Course in Credibility Theory and its Applications*. Berlim: Springer, 2005.
