import {Cell} from "@ton/core";
import {extractCompilableConfig} from "@ton/blueprint/dist/compile/compile";
import {doCompileFunc} from "@ton/blueprint/dist/compile/func/compile.func";
import fs from "fs";
import {doCompileTolk} from "@ton/blueprint/dist/compile/tolk/compile.tolk";

const PROJECT_ROOT = __dirname + '/../';
const CONTRACTS_FUNC_ROOT = `${PROJECT_ROOT}/contracts_FunC/`;
const CONTRACTS_TOLK_ROOT = `${PROJECT_ROOT}/contracts_Tolk/`;
const WRAPPERS_ROOT = `${PROJECT_ROOT}/wrappers/`;
const FIFT_OUTPUT_ROOT = `${PROJECT_ROOT}/fift-output/`;

// Always send fift output after compilation.
// Achieve the following structure:
// - fift-output/
// |-- 01_jetton
// |----- JettonMinter.before.fif
// |----- JettonMinter.now.fif
// |-- 02...
// As a result, it's easy to compare fif output when making minor changes and rolling them back.
// To save specific versions for later comparison, copy fif files manually.
function saveFiftOutput(numericFolder: string, contractName: string, fiftOutput: string) {
    const dirInFiftFolder = FIFT_OUTPUT_ROOT + numericFolder;
    if (!fs.existsSync(dirInFiftFolder)) {
        fs.mkdirSync(dirInFiftFolder);
    }
    const prevFifFileName = dirInFiftFolder + '/' + contractName + '.before.fif';
    const curFifFileName = dirInFiftFolder + '/' + contractName + '.now.fif';
    if (fs.existsSync(curFifFileName)) {
        fs.renameSync(curFifFileName, prevFifFileName);
    }
    fs.writeFileSync(curFifFileName, fiftOutput, 'utf-8');
}

// `myCompile` is a replacement for `compile` that searches for `.compile.ts` inside a given folder
// and also saves fif output.
export async function myCompile(numericFolder: string, contractName: string): Promise<Cell> {
    const compileTsFileName = WRAPPERS_ROOT + numericFolder + '/' + contractName + '.compile.ts';
    const config = extractCompilableConfig(compileTsFileName);
    try {
        let codeCell: Cell;
        let fiftOutput: string;
        if (config.lang === 'func') {
            let funcResult = await doCompileFunc({
                targets: config.targets!,
                sources: path => fs.readFileSync(CONTRACTS_FUNC_ROOT + numericFolder + '/' + path, 'utf-8'),
                optLevel: 2,
            });
            codeCell = funcResult.code;
            fiftOutput = funcResult.fiftCode;
        } else if (config.lang === 'tolk') {
            let tolkResult = await doCompileTolk({
                entrypointFileName: config.entrypoint,
                optimizationLevel: config.optimizationLevel,
                experimentalOptions: config.experimentalOptions,
                withSrcLineComments: config.withSrcLineComments,
                withStackComments: config.withStackComments,
                fsReadCallback: path => fs.readFileSync(CONTRACTS_TOLK_ROOT + numericFolder + '/' + path, 'utf-8'),
            });
            codeCell = tolkResult.code;
            fiftOutput = tolkResult.fiftCode;
        } else {
            // noinspection ExceptionCaughtLocallyJS
            throw "Unknown compiler type: " + config.lang;
        }

        saveFiftOutput(numericFolder, contractName, fiftOutput);
        return codeCell;
    } catch (ex) {
        process.stdout.write(`❌ Compilation failed for ${numericFolder}/${contractName}\n\n`);
        process.stdout.write((ex as any).toString());
        process.exit(1);
    }
}
