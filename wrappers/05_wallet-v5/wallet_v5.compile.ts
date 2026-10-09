import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    // lang: 'func',
    // targets: ['wallet_v5.fc']
    lang: 'tolk',
    entrypoint: 'wallet-v5-contract.tolk',
    withSrcLineComments: true,
    withStackComments: true,
};
