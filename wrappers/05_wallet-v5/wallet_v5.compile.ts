import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    // lang: 'func',
    // targets: ['wallet_v5.fc']
    lang: 'tolk',
    entrypoint: 'wallet_v5.tolk',
    withSrcLineComments: true,
    withStackComments: true,
};
