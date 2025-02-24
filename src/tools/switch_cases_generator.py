# case 20:
#     noop = 0;break;
# case 21:
#     noop = 1;break;
# case 222:
#     noop = 2;break;
# case 223:
#     noop = 3;break;
# case 224:
#     noop = 4;break;
# case 225:
#     noop = 5;break;
# case 226:
#     noop = 6;break;
# case 227:
#     noop = 7;break;
# case 228:
#     noop = 8;break;
# case 229:
#     noop = 9;break;
# case 210:
#     noop = 10;break;
# case 211:
#     noop = 11;break;
# case 212:
#     noop = 12;break;
# case 213:
#     noop = 13;break;
# case 214:
#     noop = 14;break;
# case 215:
#     noop = 15;break;
# case 216:
#     noop = 16;break;
# case 217:
#     noop = 17;break;
# case 218:
#     noop = 18;break;
# case 219:
#     noop = 19;break;
# case 220:
#     noop = 20;break;
# case 221:
#     noop = 21;break;
# case 222:
#     noop = 22;break;
# case 223:
#     noop = 23;break;
# case 224:
#     noop = 24;break;
# case 225:
#     noop = 25;break;
# case 226:
#     noop = 26;break;
# case 227:
#     noop = 27;break;
# case 228:
#     noop = 28;break;
# case 229:
#     noop = 29;break;
# case 230:
#     noop = 30;break;
# case 231:
#     noop = 31;break;
# case 232:
#     noop = 32;break;
# case 233:
#     noop = 33;break;
# case 234:
#     noop = 34;break;
# case 235:
#     noop = 35;break;
# case 236:
#     noop = 36;break;
# case 237:
#     noop = 37;break;
# case 238:
#     noop = 38;break;
# case 239:
#     noop = 39;break;
# case 240:
#     noop = 40;break;
# case 241:
#     noop = 41;break;
# case 242:
#     noop = 42;break;
# case 243:
#     noop = 43;break;
# case 244:
#     noop = 44;break;
# case 245:
#     noop = 45;break;
# case 246:
#     noop = 46;break;
# case 247:
#     noop = 47;break;
# case 248:
#     noop = 48;break;
# case 249:
#     noop = 49;break;
# case 250:
#     noop = 50;break;
# case 251:
#     noop = 51;break;
# case 252:
#     noop = 52;break;
# case 253:
#     noop = 53;break;
# case 254:
#     noop = 54;break;
# case 255:
#     noop = 55;break;
# case 256:
#     noop = 56;break;
# case 257:
#     noop = 57;break;
# case 258:
#     noop = 58;break;
# case 259:
#     noop = 59;break;
# case 260:
#     noop = 60;break;
# case 261:
#     noop = 61;break;
# case 262:
#     noop = 62;break;
# case 263:
#     noop = 63;break;
# case 264:
#     noop = 64;break;
# case 265:
#     noop = 65;break;
# case 266:
#     noop = 66;break;
# case 267:
#     noop = 67;break;
# case 268:
#     noop = 68;break;
# case 269:
#     noop = 69;break;
# case 270:
#     noop = 70;break;
# case 271:
#     noop = 71;break;
# case 272:
#     noop = 72;break;
# case 273:
#     noop = 73;break;
# case 274:
#     noop = 74;break;
# case 275:
#     noop = 75;break;
# case 276:
#     noop = 76;break;
# case 277:
#     noop = 77;break;
# case 278:
#     noop = 78;break;
# case 279:
#     noop = 79;break;
# case 280:
#     noop = 80;break;
# case 281:
#     noop = 81;break;
# case 282:
#     noop = 82;break;
# case 283:
#     noop = 83;break;
# case 284:
#     noop = 84;break;
# case 285:
#     noop = 85;break;
# case 286:
#     noop = 86;break;
# case 287:
#     noop = 87;break;
# case 288:
#     noop = 88;break;
# case 289:
#     noop = 89;break;
# case 290:
#     noop = 90;break;
# case 291:
#     noop = 91;break;
# case 292:
#     noop = 92;break;
# case 293:
#     noop = 93;break;
# case 294:
#     noop = 94;break;
# case 295:
#     noop = 95;break;
# case 296:
#     noop = 96;break;
# case 297:
#     noop = 97;break;
# case 298:
#     noop = 98;break;
# case 299:
#     noop = 99;break;

pattern = '''
case %d:
    noop = %d;break;'''
res = ''
for i in range(0, 1_000):
  res += pattern % (i, i)

print(res)
