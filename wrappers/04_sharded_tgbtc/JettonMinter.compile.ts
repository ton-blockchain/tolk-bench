import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    // lang: 'func',
    // targets: ['jetton-minter.fc'],
    lang: 'tolk',
    entrypoint: 'jetton-minter-contract.tolk',
    withSrcLineComments: true,
    withStackComments: true,
};
