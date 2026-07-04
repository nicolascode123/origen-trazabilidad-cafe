// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

interface ISupplyChainTraceability {
    function registrarCheckpoint(
        uint256 tokenId,
        int256 temperaturaCelsiusX10,
        uint256 humedadPorcentajeX10
    ) external;
}

/**
 * @title IoTOracle
 * @notice Contrato "oráculo" que conecta datos del mundo real (sensores IoT de
 *         temperatura/humedad instalados en los contenedores de transporte) con
 *         el contrato de trazabilidad on-chain. Sigue el patrón
 *         request -> off-chain compute -> fulfill que usan oráculos como
 *         Chainlink: un nodo autorizado firma y publica la lectura del sensor,
 *         el contrato la valida y la reenvía a SupplyChainTraceability.
 *
 *         Esto evita que el contrato principal confíe ciegamente en cualquier
 *         cuenta: solo direcciones dadas de alta como `nodoOraculo` (ej. un
 *         gateway IoT operado por la distribuidora, o un servicio tipo
 *         Chainlink Functions) pueden alimentar datos.
 */
contract IoTOracle is Ownable {
    ISupplyChainTraceability public immutable contratoTrazabilidad;
    mapping(address => bool) public nodosAutorizados;

    event NodoOraculoAutorizado(address indexed nodo);
    event NodoOraculoRevocado(address indexed nodo);
    event LecturaSensorPublicada(uint256 indexed tokenId, int256 temperaturaX10, uint256 humedadX10, address indexed nodo);

    constructor(address direccionContratoTrazabilidad) Ownable(msg.sender) {
        contratoTrazabilidad = ISupplyChainTraceability(direccionContratoTrazabilidad);
    }

    modifier soloNodoAutorizado() {
        require(nodosAutorizados[msg.sender], "Nodo oraculo no autorizado");
        _;
    }

    function autorizarNodo(address nodo) external onlyOwner {
        nodosAutorizados[nodo] = true;
        emit NodoOraculoAutorizado(nodo);
    }

    function revocarNodo(address nodo) external onlyOwner {
        nodosAutorizados[nodo] = false;
        emit NodoOraculoRevocado(nodo);
    }

    /**
     * @notice Publica una lectura de sensor IoT (temperatura/humedad) para un lote.
     *         Llamada por el nodo oráculo autorizado; internamente reenvía el dato
     *         al contrato de trazabilidad, que ya le otorgó ORACLE_ROLE a esta
     *         dirección de contrato.
     */
    function publicarLectura(
        uint256 tokenId,
        int256 temperaturaCelsiusX10,
        uint256 humedadPorcentajeX10
    ) external soloNodoAutorizado {
        contratoTrazabilidad.registrarCheckpoint(tokenId, temperaturaCelsiusX10, humedadPorcentajeX10);
        emit LecturaSensorPublicada(tokenId, temperaturaCelsiusX10, humedadPorcentajeX10, msg.sender);
    }
}
