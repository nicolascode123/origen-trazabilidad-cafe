// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title SupplyChainTraceability
 * @notice Aplicación descentralizada (DApp) para la trazabilidad de una cadena de
 *         suministro de productos agrícolas (ej. café de origen). Cada lote de
 *         producto es representado por un token NFT (ERC-721) que actúa como
 *         "certificado digital" de origen y va acumulando un historial inmutable
 *         de custodia y checkpoints de calidad (temperatura / humedad) reportados
 *         por un oráculo.
 *
 * Elementos exigidos por la EFT (BCY0010):
 *  - Participantes: PRODUCTOR_ROLE, DISTRIBUIDOR_ROLE, MINORISTA_ROLE, ORACLE_ROLE
 *  - Términos y condiciones (lógica del acuerdo): reglas de transición de estado
 *    codificadas en `transferirCustodia` y en el modificador `soloSiguienteEtapa`
 *  - Funciones (operaciones): registrarLote, transferirCustodia, registrarCheckpoint,
 *    confirmarEntregaFinal, verificarLote
 *  - Estado (datos actuales): struct Lote y su enum EstadoLote
 *  - Firma digital: `transferirCustodia` exige una firma ECDSA del receptor sobre el
 *    hash de la transacción de traspaso, verificada on-chain con ECDSA.recover
 */
contract SupplyChainTraceability is ERC721, AccessControl {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ---------------------------------------------------------------------
    // Roles (participantes del ecosistema)
    // ---------------------------------------------------------------------
    bytes32 public constant PRODUCTOR_ROLE   = keccak256("PRODUCTOR_ROLE");
    bytes32 public constant DISTRIBUIDOR_ROLE = keccak256("DISTRIBUIDOR_ROLE");
    bytes32 public constant MINORISTA_ROLE    = keccak256("MINORISTA_ROLE");
    bytes32 public constant ORACLE_ROLE       = keccak256("ORACLE_ROLE");

    // ---------------------------------------------------------------------
    // Estado (datos actuales)
    // ---------------------------------------------------------------------
    enum EstadoLote { Creado, EnTransitoDistribuidor, EnBodegaMinorista, Entregado }

    struct CheckpointCalidad {
        int256 temperaturaCelsiusX10; // temperatura * 10 para evitar decimales
        uint256 humedadPorcentajeX10; // humedad relativa * 10
        uint256 timestamp;
        address reportadoPor; // dirección del oráculo que reportó el dato
    }

    struct Lote {
        string nombreProducto;   // ej. "Café Arábica - Finca Los Robles"
        string origen;           // ej. "Región del Biobío, Chile"
        uint256 fechaCosecha;    // timestamp de cosecha
        EstadoLote estado;
        address productor;
        address distribuidorActual;
        address minoristaActual;
        bool condicionesRespetadas; // true si nunca rompió el rango seguro de temperatura
    }

    uint256 private _nextTokenId;
    mapping(uint256 => Lote) public lotes;
    mapping(uint256 => CheckpointCalidad[]) public historialCalidad;
    mapping(uint256 => address[]) public historialCustodia; // trazabilidad completa de dueños
    mapping(address => uint256) public nonces; // anti-replay para firmas de traspaso

    // Rango seguro de temperatura para transporte refrigerado (en °C * 10)
    int256 public constant TEMP_MIN = 20;   // 2.0 °C
    int256 public constant TEMP_MAX = 80;   // 8.0 °C

    // ---------------------------------------------------------------------
    // Eventos (permiten reconstruir toda la trazabilidad fuera de la cadena)
    // ---------------------------------------------------------------------
    event LoteRegistrado(uint256 indexed tokenId, address indexed productor, string nombreProducto, string origen);
    event CustodiaTransferida(uint256 indexed tokenId, address indexed desde, address indexed hacia, EstadoLote nuevoEstado);
    event CheckpointRegistrado(uint256 indexed tokenId, int256 temperaturaX10, uint256 humedadX10, bool dentroDeRango);
    event LoteEntregado(uint256 indexed tokenId, address indexed minorista, bool condicionesRespetadas);

    constructor() ERC721("SupplyChainBatchCertificate", "SCBC") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PRODUCTOR_ROLE, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Administración de participantes (solo el admin del despliegue)
    // ---------------------------------------------------------------------
    function registrarProductor(address cuenta) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(PRODUCTOR_ROLE, cuenta);
    }

    function registrarDistribuidor(address cuenta) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(DISTRIBUIDOR_ROLE, cuenta);
    }

    function registrarMinorista(address cuenta) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(MINORISTA_ROLE, cuenta);
    }

    function registrarOraculo(address cuenta) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(ORACLE_ROLE, cuenta);
    }

    // ---------------------------------------------------------------------
    // 1) Registro de un nuevo lote (mint del NFT certificado) — solo Productor
    // ---------------------------------------------------------------------
    function registrarLote(
        string calldata nombreProducto,
        string calldata origen,
        uint256 fechaCosecha
    ) external onlyRole(PRODUCTOR_ROLE) returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _safeMint(msg.sender, tokenId);

        lotes[tokenId] = Lote({
            nombreProducto: nombreProducto,
            origen: origen,
            fechaCosecha: fechaCosecha,
            estado: EstadoLote.Creado,
            productor: msg.sender,
            distribuidorActual: address(0),
            minoristaActual: address(0),
            condicionesRespetadas: true
        });

        historialCustodia[tokenId].push(msg.sender);
        emit LoteRegistrado(tokenId, msg.sender, nombreProducto, origen);
        return tokenId;
    }

    // ---------------------------------------------------------------------
    // 2) Transferencia de custodia con firma digital del receptor
    //    (términos y condiciones: solo se puede avanzar a la SIGUIENTE etapa)
    // ---------------------------------------------------------------------
    function transferirCustodia(
        uint256 tokenId,
        address receptor,
        bytes calldata firmaReceptor
    ) external {
        Lote storage lote = lotes[tokenId];
        require(_ownerOf(tokenId) != address(0), "Lote inexistente");

        // Mensaje que el receptor debe haber firmado off-chain (ej. desde su wallet)
        bytes32 mensaje = keccak256(
            abi.encodePacked(tokenId, receptor, nonces[receptor], address(this))
        ).toEthSignedMessageHash();
        address firmante = mensaje.recover(firmaReceptor);
        require(firmante == receptor, "Firma digital invalida del receptor");
        nonces[receptor]++;

        if (lote.estado == EstadoLote.Creado) {
            require(hasRole(DISTRIBUIDOR_ROLE, receptor), "Receptor debe ser Distribuidor");
            require(msg.sender == lote.productor, "Solo el productor entrega el lote");
            lote.distribuidorActual = receptor;
            lote.estado = EstadoLote.EnTransitoDistribuidor;
        } else if (lote.estado == EstadoLote.EnTransitoDistribuidor) {
            require(hasRole(MINORISTA_ROLE, receptor), "Receptor debe ser Minorista");
            require(msg.sender == lote.distribuidorActual, "Solo el distribuidor actual entrega el lote");
            lote.minoristaActual = receptor;
            lote.estado = EstadoLote.EnBodegaMinorista;
        } else {
            revert("Transicion de estado no permitida");
        }

        _safeTransfer(msg.sender, receptor, tokenId, "");
        historialCustodia[tokenId].push(receptor);
        emit CustodiaTransferida(tokenId, msg.sender, receptor, lote.estado);
    }

    // ---------------------------------------------------------------------
    // 3) Checkpoint de calidad reportado por el oráculo (dato del mundo real)
    // ---------------------------------------------------------------------
    function registrarCheckpoint(
        uint256 tokenId,
        int256 temperaturaCelsiusX10,
        uint256 humedadPorcentajeX10
    ) external onlyRole(ORACLE_ROLE) {
        require(_ownerOf(tokenId) != address(0), "Lote inexistente");

        bool dentroDeRango = temperaturaCelsiusX10 >= TEMP_MIN && temperaturaCelsiusX10 <= TEMP_MAX;
        if (!dentroDeRango) {
            lotes[tokenId].condicionesRespetadas = false;
        }

        historialCalidad[tokenId].push(CheckpointCalidad({
            temperaturaCelsiusX10: temperaturaCelsiusX10,
            humedadPorcentajeX10: humedadPorcentajeX10,
            timestamp: block.timestamp,
            reportadoPor: msg.sender
        }));

        emit CheckpointRegistrado(tokenId, temperaturaCelsiusX10, humedadPorcentajeX10, dentroDeRango);
    }

    // ---------------------------------------------------------------------
    // 4) Confirmación de entrega final al consumidor — solo Minorista actual
    // ---------------------------------------------------------------------
    function confirmarEntregaFinal(uint256 tokenId) external {
        Lote storage lote = lotes[tokenId];
        require(lote.estado == EstadoLote.EnBodegaMinorista, "El lote no esta en bodega del minorista");
        require(msg.sender == lote.minoristaActual, "Solo el minorista actual puede confirmar");

        lote.estado = EstadoLote.Entregado;
        emit LoteEntregado(tokenId, msg.sender, lote.condicionesRespetadas);
    }

    // ---------------------------------------------------------------------
    // 5) Lectura / verificación pública del lote (trazabilidad para el consumidor)
    // ---------------------------------------------------------------------
    function verificarLote(uint256 tokenId)
        external
        view
        returns (
            Lote memory datosLote,
            address[] memory custodios,
            CheckpointCalidad[] memory checkpoints
        )
    {
        require(_ownerOf(tokenId) != address(0), "Lote inexistente");
        return (lotes[tokenId], historialCustodia[tokenId], historialCalidad[tokenId]);
    }

    function totalLotes() external view returns (uint256) {
        return _nextTokenId;
    }

    // Requerido por Solidity al heredar de dos contratos con supportsInterface
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
