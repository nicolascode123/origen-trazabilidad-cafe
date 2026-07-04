const fs = require("fs");
const path = require("path");
const solc = require("solc");

function findImports(importPath) {
  try {
    const fullPath = path.resolve(__dirname, "node_modules", importPath);
    return { contents: fs.readFileSync(fullPath, "utf8") };
  } catch (e) {
    return { error: "File not found: " + importPath };
  }
}

const contractsDir = path.join(__dirname, "contracts");
const files = fs.readdirSync(contractsDir).filter((f) => f.endsWith(".sol"));

const sources = {};
for (const f of files) {
  sources[f] = { content: fs.readFileSync(path.join(contractsDir, f), "utf8") };
}

const input = {
  language: "Solidity",
  sources,
  settings: {
    optimizer: { enabled: true, runs: 200 },
    evmVersion: "cancun",
    outputSelection: {
      "*": {
        "*": ["abi", "evm.bytecode.object", "evm.gasEstimates"],
      },
    },
  },
};

const output = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));

let hasError = false;
if (output.errors) {
  for (const err of output.errors) {
    if (err.severity === "error") {
      hasError = true;
      console.error("ERROR:\n" + err.formattedMessage);
    } else {
      console.warn("WARNING:\n" + err.formattedMessage);
    }
  }
}

if (!hasError) {
  const outDir = path.join(__dirname, "build");
  fs.mkdirSync(outDir, { recursive: true });
  for (const fileName of Object.keys(output.contracts)) {
    for (const contractName of Object.keys(output.contracts[fileName])) {
      const contract = output.contracts[fileName][contractName];
      const artifact = {
        contractName,
        abi: contract.abi,
        bytecode: "0x" + contract.evm.bytecode.object,
      };
      fs.writeFileSync(
        path.join(outDir, contractName + ".json"),
        JSON.stringify(artifact, null, 2)
      );
      console.log(`Compiled OK: ${contractName} (bytecode size: ${contract.evm.bytecode.object.length / 2} bytes)`);
    }
  }
  console.log("\n✅ Compilación exitosa. ABIs y bytecode guardados en /build");
} else {
  console.error("\n❌ Compilación con errores.");
  process.exit(1);
}
