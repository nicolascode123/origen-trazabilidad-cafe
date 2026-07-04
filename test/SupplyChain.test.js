const { expect } = require("chai");
const { ethers } = require("ethers");
const ganache = require("ganache");
const fs = require("fs");
const path = require("path");

const buildDir = path.join(__dirname, "..", "build");
function loadArtifact(name) {
  return JSON.parse(fs.readFileSync(path.join(buildDir, name + ".json"), "utf8"));
}

describe("SupplyChainTraceability + IoTOracle (caso: trazabilidad de cafe de origen)", function () {
  this.timeout(60000);

  let provider, server;
  let admin, productor, distribuidor, minorista, nodoIoT, consumidor;
  let trazabilidad, oraculo;
  const PORT = 8545;

  beforeEach(async function () {
    server = ganache.server({ logging: { quiet: true } });
    await new Promise((resolve) => server.listen(PORT, resolve));
    provider = new ethers.JsonRpcProvider(`http://127.0.0.1:${PORT}`, undefined, {
      staticNetwork: true,
      batchMaxCount: 1,
    });

    // Usamos wallets locales (con su clave privada) en vez de dejar que el
    // proveedor gestione las cuentas, ya que necesitamos firmar mensajes
    // fuera de la cadena (personal_sign) tal como lo haria MetaMask en el
    // navegador: la wallet del receptor firma localmente con su clave privada.
    const initialAccounts = await server.provider.getInitialAccounts();
    const secretKeys = Object.values(initialAccounts).map((a) => a.secretKey);
    [admin, productor, distribuidor, minorista, nodoIoT, consumidor] = secretKeys
      .slice(0, 6)
      .map((sk) => new ethers.Wallet(sk, provider));

    // El proveedor JSON-RPC puede devolver un nonce desactualizado si se
    // consulta justo despues de minar una transaccion. Para evitar
    // colisiones, llevamos la cuenta del nonce nosotros mismos, tal como
    // haria una wallet real con gestion de nonce local.
    const nonceTracker = new Map();
    for (const w of [admin, productor, distribuidor, minorista, nodoIoT, consumidor]) {
      nonceTracker.set(w.address, 0);
      w.getNonce = async () => {
        const current = nonceTracker.get(w.address);
        nonceTracker.set(w.address, current + 1);
        return current;
      };
    }

    const trazArtifact = loadArtifact("SupplyChainTraceability");
    const trazFactory = new ethers.ContractFactory(trazArtifact.abi, trazArtifact.bytecode, admin);
    trazabilidad = await trazFactory.deploy();
    await trazabilidad.waitForDeployment();

    const oracleArtifact = loadArtifact("IoTOracle");
    const oracleFactory = new ethers.ContractFactory(oracleArtifact.abi, oracleArtifact.bytecode, admin);
    oraculo = await oracleFactory.deploy(await trazabilidad.getAddress());
    await oraculo.waitForDeployment();

    await (await trazabilidad.registrarProductor(await productor.getAddress())).wait();
    await (await trazabilidad.registrarDistribuidor(await distribuidor.getAddress())).wait();
    await (await trazabilidad.registrarMinorista(await minorista.getAddress())).wait();
    await (await trazabilidad.registrarOraculo(await oraculo.getAddress())).wait();
    await (await oraculo.autorizarNodo(await nodoIoT.getAddress())).wait();
  });

  afterEach(async function () {
    if (provider && provider.destroy) provider.destroy();
    if (server) await server.close();
  });

  async function firmarAceptacion(receptorSigner, tokenId) {
    const receptorAddr = await receptorSigner.getAddress();
    const nonce = await trazabilidad.nonces(receptorAddr);
    const contractAddr = await trazabilidad.getAddress();
    const hash = ethers.solidityPackedKeccak256(
      ["uint256", "address", "uint256", "address"],
      [tokenId, receptorAddr, nonce, contractAddr]
    );
    return receptorSigner.signMessage(ethers.getBytes(hash));
  }

  it("registra un nuevo lote y emite el certificado NFT (token) al productor", async function () {
    const productorAddr = await productor.getAddress();
    const tx = await trazabilidad
      .connect(productor)
      .registrarLote("Cafe Arabica - Finca Los Robles", "Region del Biobio, Chile", 1735689600);
    const receipt = await tx.wait();
    expect(receipt.status).to.equal(1);

    expect(await trazabilidad.ownerOf(0)).to.equal(productorAddr);
    const lote = await trazabilidad.lotes(0);
    expect(lote.nombreProducto).to.equal("Cafe Arabica - Finca Los Robles");
    expect(lote.estado).to.equal(0n); // Creado
  });

  it("transfiere la custodia Productor -> Distribuidor con firma digital valida del receptor", async function () {
    await (await trazabilidad.connect(productor).registrarLote("Cafe Arabica", "Biobio", 1735689600)).wait();
    const tokenId = 0;
    const distribuidorAddr = await distribuidor.getAddress();

    const firma = await firmarAceptacion(distribuidor, tokenId);
    const tx = await trazabilidad.connect(productor).transferirCustodia(tokenId, distribuidorAddr, firma);
    const receipt = await tx.wait();
    expect(receipt.status).to.equal(1);

    expect(await trazabilidad.ownerOf(tokenId)).to.equal(distribuidorAddr);
    const lote = await trazabilidad.lotes(tokenId);
    expect(lote.estado).to.equal(1n); // EnTransitoDistribuidor
  });

  it("rechaza una transferencia de custodia con firma invalida (seguridad)", async function () {
    await (await trazabilidad.connect(productor).registrarLote("Cafe Arabica", "Biobio", 1735689600)).wait();
    const tokenId = 0;
    const distribuidorAddr = await distribuidor.getAddress();

    const nonce = await trazabilidad.nonces(distribuidorAddr);
    const contractAddr = await trazabilidad.getAddress();
    const hash = ethers.solidityPackedKeccak256(
      ["uint256", "address", "uint256", "address"],
      [tokenId, distribuidorAddr, nonce, contractAddr]
    );
    const firmaInvalida = await consumidor.signMessage(ethers.getBytes(hash));

    let revertido = false;
    try {
      const tx = await trazabilidad
        .connect(productor)
        .transferirCustodia(tokenId, distribuidorAddr, firmaInvalida, { gasLimit: 300000 });
      await tx.wait();
    } catch (e) {
      revertido = true;
      expect(String(e.reason || e.shortMessage || e.message || e).toLowerCase()).to.include("revert");
    }
    expect(revertido).to.equal(true);
  });

  it("el oraculo IoT publica checkpoints de temperatura/humedad y detecta ruptura de cadena de frio", async function () {
    await (await trazabilidad.connect(productor).registrarLote("Cafe Arabica", "Biobio", 1735689600)).wait();
    const tokenId = 0;

    let tx = await oraculo.connect(nodoIoT).publicarLectura(tokenId, 45, 600);
    await tx.wait();

    tx = await oraculo.connect(nodoIoT).publicarLectura(tokenId, 120, 550);
    await tx.wait();

    const lote = await trazabilidad.lotes(tokenId);
    expect(lote.condicionesRespetadas).to.equal(false);

    const [, , checkpoints] = await trazabilidad.verificarLote(tokenId);
    expect(checkpoints.length).to.equal(2);
  });

  it("un nodo IoT no autorizado no puede publicar lecturas", async function () {
    await (await trazabilidad.connect(productor).registrarLote("Cafe Arabica", "Biobio", 1735689600)).wait();
    let revertido = false;
    try {
      const tx = await oraculo.connect(consumidor).publicarLectura(0, 45, 600, { gasLimit: 300000 });
      await tx.wait();
    } catch (e) {
      revertido = true;
      expect(String(e.reason || e.shortMessage || e.message || e).toLowerCase()).to.include("revert");
    }
    expect(revertido).to.equal(true);
  });

  it("flujo completo: Productor -> Distribuidor -> Minorista -> Entrega final, y verificacion publica", async function () {
    await (await trazabilidad.connect(productor).registrarLote("Cafe Arabica", "Biobio", 1735689600)).wait();
    const tokenId = 0;
    const distribuidorAddr = await distribuidor.getAddress();
    const minoristaAddr = await minorista.getAddress();

    let firma = await firmarAceptacion(distribuidor, tokenId);
    await (await trazabilidad.connect(productor).transferirCustodia(tokenId, distribuidorAddr, firma)).wait();

    await (await oraculo.connect(nodoIoT).publicarLectura(tokenId, 40, 580)).wait();

    firma = await firmarAceptacion(minorista, tokenId);
    await (await trazabilidad.connect(distribuidor).transferirCustodia(tokenId, minoristaAddr, firma)).wait();

    const tx = await trazabilidad.connect(minorista).confirmarEntregaFinal(tokenId);
    const receipt = await tx.wait();
    expect(receipt.status).to.equal(1);

    const [datosLote, custodios, checkpoints] = await trazabilidad.connect(consumidor).verificarLote(tokenId);
    expect(datosLote.estado).to.equal(3n); // Entregado
    expect(custodios.length).to.equal(3);
    expect(checkpoints.length).to.equal(1);
  });
});
