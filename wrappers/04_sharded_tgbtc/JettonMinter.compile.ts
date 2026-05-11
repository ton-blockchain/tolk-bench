import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    // lang: 'func',
    // targets: ['jetton-minter.fc'],
    lang: 'tolk',
    entrypoint: 'JettonMinter.tolk',
    withSrcLineComments: true,
    withStackComments: true,
};
