# Site do Grupo BVEK (www.bvek.com.br e www.grupobvek.com.br)

Página única que apresenta o Grupo BVEK e as quatro empresas (Engekat, Verde Brasilis, BrasiLimp e Kat Seguros).
Tudo está nesta pasta `site/`: `index.html` (textos e visual), `img/` (logos), `vercel.json`.

## Publicar (uma vez só)

1. Na Vercel: **Add New → Project** → escolha o repositório `GRUPO-BVEK`.
2. Em **Root Directory**, clique em *Edit* e escolha a pasta **`site`**. Framework: *Other*. Clique em **Deploy**.
   (É um projeto separado do CRM: o CRM continua em grupo-bvek.vercel.app.)
3. No projeto novo: **Settings → Domains** → adicione `bvek.com.br`, `www.bvek.com.br`, `grupobvek.com.br` e `www.grupobvek.com.br`.
   Deixe o `www.bvek.com.br` como principal e os outros redirecionando para ele.
4. No **Registro.br** (registro.br → Painel → domínio → *Editar zona* / DNS), crie para **cada** domínio
   os registros que a Vercel mostrar na tela de Domains. Normalmente são:
   - `A` com nome vazio (o domínio sem www) → `76.76.21.21`
   - `CNAME` com nome `www` → `cname.vercel-dns.com`
   Use os valores que a Vercel mostrar, se forem diferentes. Em algumas horas o site entra no ar com HTTPS.

**Atenção:** se os domínios já têm e-mail (registros MX), não apague esses registros — só acrescente os de cima.

## Mudar textos

Edite `site/index.html` (os textos estão em português, entre as marcações) e faça o commit: a Vercel publica sozinha.
