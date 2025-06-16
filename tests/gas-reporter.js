const fs = require('node:fs');
const colors = require('ansi-colors');

// this file is .js (not .ts) to be able to called as a reporter (see jest.config.js)

const ROOT_DIR = __dirname + "/../bench-snapshots/";

class GasReporter {
    // this function is automatically called by jest after finishing all tests;
    // show table of last run VS last saved bench
    onRunComplete() {
        for (let {numericFolder} of this.getAllContracts()) {
            const lastRun = this.parseLastRunForContract(numericFolder);
            if (lastRun == null)
                continue

            const allSavedRuns = this.parseAllBenchesForContract(numericFolder);
            const lastBench = allSavedRuns.length ? allSavedRuns.pop() : null;

            let table = this.prepareTableOldVsNew(lastBench, lastRun)
            console.log(`\n •  ${colors.bold(numericFolder)}`);
            console.log(`    prev: ${lastBench ? lastBench.commitDesc : 'none'}\n`);
            console.log(table.join('\n'));
        }
    }

    /** @return {{numericFolder:string, shortTitle:string, description:string, originalUrl:string}[]} */
    getAllContracts() {
        return JSON.parse(fs.readFileSync(ROOT_DIR + '../all-contracts.json', 'utf8'))
    }

    getLastRunFileName(/**string*/ numericFolder) {
        return ROOT_DIR + numericFolder + '.last.json';
    }

    getBenchFileName(/**string*/ numericFolder) {
        return ROOT_DIR + numericFolder + '.json';
    }

    /** @return {{gas: Object<number>, codeSize: Object<number>} | null} */
    parseLastRunForContract(/**string*/ numericFolder) {
        let filename = this.getLastRunFileName(numericFolder);
        if (!fs.existsSync(filename)) {
            return null;
        }
        return JSON.parse(fs.readFileSync(filename, 'utf8'))
    }

    /** @return {{commitDesc: string, gas: Object<number>, codeSize: Object<number>}[]} */
    parseAllBenchesForContract(/**string*/ numericFolder) {
        let filename = this.getBenchFileName(numericFolder);
        if (!fs.existsSync(filename)) {
            return [];
        }
        return JSON.parse(fs.readFileSync(filename, 'utf8'));
    }

    /**
     *
     * @param {{gas: Object<number>, codeSize: Object<number>} | null} oldRun
     * @param {{gas: Object<number>, codeSize: Object<number>}} lastRun
     * @returns {string[]}
     */
    prepareTableOldVsNew(oldRun, lastRun) {
        let table = []

        for (let key in lastRun.codeSize) {     // {"xxx bits": n, "xxx cells": m}
            if (!key.endsWith(" bits"))         // handle only "bits", join bits+cells to one line
                continue
            key = key.substring(0, key.length - 5);

            let curBits = lastRun.codeSize[key + " bits"];
            let curCells = lastRun.codeSize[key + " cells"];
            let prevBits = oldRun ? oldRun.codeSize[key + " bits"] : null;
            let prevCells = oldRun ? oldRun.codeSize[key + " cells"] : null;

            let s = `    ${(key + " (bits / cells)").padEnd(40)} `
            if (prevBits && prevCells) {
                s += `${prevBits} / ${prevCells} `
                if (curBits <= prevBits && curCells <= prevCells && (curBits < prevBits || curCells < prevCells))
                    s += colors.greenBright(`→ ${curBits} / ${curCells}`)
                else if (curBits !== prevBits || curCells !== prevCells)
                    s += `→ ${curBits} / ${curCells}`
                else
                    s += `=`
            } else {
                s += `${curBits} / ${curCells}`
            }
            table.push(s)
        }

        for (let key in lastRun.gas) {          // {"step1": n, "step2": m}
            let curGas = lastRun.gas[key];
            let prevGas = oldRun ? oldRun.gas[key] : null;

            let s = `    ${key.padEnd(40)} `
            if (prevGas) {
                s += `${prevGas.toString().padEnd(7)} `
                if (curGas > prevGas)
                    s += colors.red(`→ ${curGas.toString().padEnd(7)} +${((curGas - prevGas) / prevGas * 100).toFixed(2)}%`)
                else if (curGas < prevGas)
                    s += colors.greenBright(`→ ${curGas.toString().padEnd(7)} -${((prevGas - curGas) / prevGas * 100).toFixed(2)}%`)
                else
                    s += `=`
            } else {
                s += `${curGas}`
            }
            table.push(s)
        }

        return table
    }

    persistLastRunIntoBenchFile(/**string*/ numericFolder, /**string*/ commitDesc) {
        const lastRun = this.parseLastRunForContract(numericFolder);
        if (lastRun === null)
            throw `lastRun is null for ${numericFolder}`

        let combinedRuns = this.parseAllBenchesForContract(numericFolder);
        combinedRuns.push({
            commitDesc: commitDesc,
            gas: lastRun.gas,
            codeSize: lastRun.codeSize,
        });
        fs.writeFileSync(this.getBenchFileName(numericFolder), JSON.stringify(combinedRuns, null, 2), 'utf8')
    }
}

module.exports = GasReporter;
