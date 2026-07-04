# Origen — Trazabilidad de café en Blockchain
### EFT · BCY0010 Fundamentos de Blockchain

DApp de trazabilidad para una cadena de suministro de café de origen (Productor → Distribuidor → Minorista → Consumidor), construida sobre Ethereum. Cada lote se representa como un certificado NFT (ERC‑721) que acumula un historial inmutable de custodia y checkpoints de calidad (temperatura/humedad) reportados por un oráculo IoT.

## Estructura del proyecto

```
proyecto-blockchain/
├── contracts/
│   ├── SupplyChainTraceability.sol   # Contrato principal (roles, lotes, custodia, firma digital)
│   └── IoTOracle.sol                 # Oráculo que conecta sensores IoT con el contrato principal
├── test/
│   └── SupplyChain.test.js           # Suite de pruebas (6 tests, flujo completo)
├── frontend/
│   ├── index.html                    # DApp (interfaz gráfica + conexión de wallet)
│   ├── abi-trazabilidad.json         # ABI del contrato principal
│   └── abi-oraculo.json              # ABI del oráculo
├── build/                            # ABI + bytecode compilados (generados por compile.js)
├── compile.js                        # Script de compilación con solc
└── package.json
```

## 1. Cómo se verificó el contrato (evidencia para el informe)

El contrato fue compilado con `solc 0.8.24` (optimizer 200 runs, EVM `cancun`) y probado de extremo a extremo con **Ganache** (blockchain local) + **ethers.js v6** en `test/SupplyChain.test.js`. Los 6 escenarios cubiertos:

1. Registro de un lote y emisión del certificado NFT.
2. Transferencia de custodia Productor → Distribuidor con firma digital ECDSA válida.
3. Rechazo de una transferencia con firma inválida (seguridad).
4. Publicación de checkpoints de temperatura/humedad vía el oráculo, y detección de ruptura de cadena de frío.
5. Rechazo de lecturas de un nodo IoT no autorizado.
6. Flujo completo: Productor → Distribuidor → Minorista → Entrega final → verificación pública.

Para volver a ejecutar las pruebas:

```bash
npm install
node compile.js          # compila los contratos a /build
npx mocha test/ --timeout 60000
```

Deberías ver `6 passing`.

## 2. Desplegar los contratos en una testnet real (Sepolia)

La forma más simple para el equipo, sin instalar nada, es usar **Remix IDE** (remix.ethereum.org):

1. Entra a https://remix.ethereum.org y crea dos archivos nuevos: `SupplyChainTraceability.sol` e `IoTOracle.sol`. Copia el contenido de la carpeta `contracts/` de este proyecto.
2. En la pestaña **Solidity Compiler**: selecciona la versión `0.8.24`, activa el optimizador (200 runs) y en "Advanced Configurations" fija el EVM Version en `cancun`. Compila ambos archivos (Remix descarga automáticamente las dependencias de OpenZeppelin desde GitHub).
3. Instala la extensión de navegador **MetaMask**, crea o usa una cuenta de prueba y cambia a la red **Sepolia**.
4. Consigue ETH de prueba gratis en un faucet de Sepolia (por ejemplo, el de Google Cloud Web3 o Alchemy — busca "Sepolia faucet").
5. En la pestaña **Deploy & Run Transactions** de Remix, selecciona "Injected Provider - MetaMask" como entorno.
6. Despliega primero `SupplyChainTraceability` (sin argumentos). Copia la dirección resultante.
7. Despliega luego `IoTOracle`, pasando como argumento del constructor la dirección del contrato anterior.
8. Desde `SupplyChainTraceability` ya desplegado, llama a `registrarOraculo(direccion_del_IoTOracle)` para autorizar al oráculo a publicar checkpoints.
9. Da de alta a los demás participantes con `registrarProductor`, `registrarDistribuidor`, `registrarMinorista` (puedes usar otras cuentas de MetaMask del equipo, o simular todos los roles con tu misma cuenta para la demo).
10. Desde `IoTOracle`, llama a `autorizarNodo(direccion_del_nodo_IoT)` para habilitar quién puede publicar lecturas de sensores.

Guarda ambas direcciones desplegadas: las necesitarás en el paso siguiente.

## 3. Configurar y usar el frontend

1. Abre `frontend/index.html` directamente en tu navegador (doble clic), o súbelo a GitHub Pages / Vercel / Netlify para tener un enlace público.
2. Haz clic en **"Configurar direcciones de contrato desplegado"** y pega las direcciones de `SupplyChainTraceability` e `IoTOracle` que obtuviste en Remix.
3. Conecta MetaMask (misma red, Sepolia) con el botón **"Conectar wallet"**.
4. Ya puedes registrar lotes, firmar aceptaciones, transferir custodia, publicar lecturas del oráculo y verificar la trazabilidad pública de cualquier lote.

> Mientras no se configuren direcciones, la interfaz funciona en **modo demo** (sin transacciones reales) para poder explorar el flujo sin gastar ETH de prueba.

## 4. Publicar el código en GitHub

```bash
git init
git add .
git commit -m "Origen: DApp de trazabilidad de café"
git branch -M main
git remote add origin https://github.com/<tu-usuario>/<tu-repo>.git
git push -u origin main
```

Entrega en AVA: el enlace del repositorio de GitHub y el enlace de la aplicación funcional (GitHub Pages, o el archivo `index.html` si la presentan localmente).

## 5. Notas para la defensa (pitch NABC)

- **Participantes / roles**: `PRODUCTOR_ROLE`, `DISTRIBUIDOR_ROLE`, `MINORISTA_ROLE`, `ORACLE_ROLE` (AccessControl de OpenZeppelin).
- **Términos y condiciones**: codificados en `transferirCustodia`, que solo permite avanzar a la *siguiente* etapa del ciclo de vida del lote.
- **Funciones/operaciones**: `registrarLote`, `transferirCustodia`, `registrarCheckpoint` / `publicarLectura`, `confirmarEntregaFinal`, `verificarLote`.
- **Estado**: struct `Lote` (enum `EstadoLote`) + historial de custodia + historial de checkpoints de calidad.
- **Firma digital**: `transferirCustodia` exige una firma ECDSA del receptor (verificada on-chain con `ECDSA.recover`), replicando el flujo `personal_sign` de una wallet real.
- **Rol de los tokens**: cada lote es un NFT ERC‑721 que actúa como certificado de origen.
- **Rol del oráculo**: `IoTOracle.sol` es el puente entre sensores del mundo físico (temperatura/humedad) y el contrato on-chain, siguiendo el patrón *request → dato externo → fulfill* usado por oráculos como Chainlink.
