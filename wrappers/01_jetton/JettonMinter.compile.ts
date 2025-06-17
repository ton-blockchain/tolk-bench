import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    lang: 'func',
    targets: [
        'params.fc',
        'op-codes.fc',
        'discovery-params.fc',
        'jetton-utils.fc',
        'jetton-minter-discoverable.fc'
    ],
};