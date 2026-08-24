// Cogchemists shared renderer + drivers.
//
// One canvas scene — the laboratory as a fixed arena: four stations across
// the top (cog, reputation, coin, hand, artifact badges), the lab bench in
// the middle where two ingredient cards slide on and a flask bubbles and
// resolves into a coloured potion, the theory board of wax seals down the
// right, and the hole-cam strip along the bottom where every seat's private
// deduction grid is shown to spectators. The endcard stamps the true
// chemistry across the strip.
//
// Fed by three drivers: live /global websocket, live /player websocket, and
// replay (from the game's /replay websocket or the static wasm bundle). All
// state derivation happens server-side / wasm-side; this file only draws
// state objects:
//   {seats:[{name,coin,reputation,score,hand[],handCount,mortar,press,
//            published[],endorsed[],say,notes,pending,grid[8][],
//            chemistries,solved,action,result} x4 by SEAT],
//    seals:[...], publicFacts:[...], bench:{seat,a,b,potion,secret}|null,
//    ingredients[8], signatures[8], round, rounds, roundsPlayed, phase,
//    demand, demands[], initiative[4], chemistry[], started, exhibited,
//    gameDone, reason}
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome. Seats
  // are red, blue, green, yellow.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  var PAPER = "#f2e8d8";
  var PAPER_DIM = "#b8ac98";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var WAX = "#a83a2c";
  var CHAR = "#3a2f26";
  var STRIP = "rgba(242, 232, 216, 0.06)";
  var ASPECT_HEX = ["#e0523a", "#45a85e", "#3f7cc4"];
  var POTION_HEX = {
    "RED+": "#e0523a", "RED-": "#e0523a",
    "GREEN+": "#45a85e", "GREEN-": "#45a85e",
    "BLUE+": "#3f7cc4", "BLUE-": "#3f7cc4",
    "MUD": "#7a6a52"
  };
  var INGREDIENTS = ["Nightcap", "Emberroot", "Fen Lily", "Widow's Salt",
    "Copper Fern", "Gravebloom", "Sunmoss", "Rime Thistle"];
  var SIGNATURES = ["R-G-B-", "R-G-B+", "R-G+B-", "R-G+B+",
    "R+G-B-", "R+G-B+", "R+G+B-", "R+G+B+"];
  // Timing of the bench: the cards slide on, the flask bubbles, then the
  // potion resolves.
  var SLIDE_MS = 600;
  var BUBBLE_MS = 1100;
  var BUBBLE_HOLD_MS = 6000;
  // A remark is capped server-side at MaxSayLen runes (sim.nim). The band
  // above the cog row is sized to hold one in full; BUBBLE_LINES_CAP only
  // stops a pathologically narrow column from demanding the whole arena.
  var MAX_SAY_LEN = 140;
  var BUBBLE_LINES_CAP = 8;
  // Word wrap leaves a ragged right edge, so a measured character budget
  // under-counts the lines actually needed by roughly this much.
  var BUBBLE_RAGGED = 1.12;
  var BUBBLE_FONT_SAMPLE =
    "the pairing has to be carrying the red aspect and I am publishing it";
  var NARROW = 640;

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = ["soldier_red_front.png", "soldier_blue_front.png",
      "soldier_green_front.png", "soldier_yellow_front.png",
      "arena_floor.png"];
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  function ingredientName(view, index) {
    var list = (view && view.ingredients) || INGREDIENTS;
    return list[index] !== undefined ? list[index] : "?";
  }

  function signatureName(view, index) {
    var list = (view && view.signatures) || SIGNATURES;
    return list[index] !== undefined ? list[index] : "?";
  }

  function fixed(value, digits) {
    return (Math.round((value || 0) * 100) / 100).toFixed(digits);
  }

  // ---- Layout --------------------------------------------------------------

  // The bubble font, shared: the layout measures the band in it and
  // drawBubble draws in it, so the two can never drift apart.
  function bubbleFont(scale) {
    return Math.round(10 * scale) +
      "px -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif";
  }

  // A FIXED arena: everything is always inside the frame, so there is no
  // zoom bar and no minimap. Four stations across the top, the bench under
  // them, the theory board down the right, the hole-cam strip along the
  // bottom.
  function computeLayout(ctx, width, height) {
    var margin = 8;
    var narrow = width < NARROW;
    var boardW = Math.max(112, Math.min(width * 0.26, 280));
    var stripH = Math.max(58, Math.min(height * 0.24, 132));
    var mainX = margin;
    var mainW = width - boardW - margin * 3;
    var mainY = margin;
    var mainH = height - stripH - margin * 3;
    var scale = Math.max(0.55, Math.min(1.5, Math.min(mainW / 640,
      mainH / 380)));
    var pitch = mainW / 4;
    var columns = [];
    for (var c = 0; c < 4; c++) {
      columns.push({ x: mainX + pitch * (c + 0.5) });
    }
    var cogSize = Math.max(26, Math.min(64 * scale, pitch * 0.42));

    // A remark runs up to MaxSayLen (140) runes, so the bubble needs a band of
    // its OWN above the cog row. Without one it was drawn at a negative y and
    // clipped off the top of the canvas. The band is reserved whether or not
    // anyone is speaking, so stations never jump when a remark lands, and it
    // is one column wide minus a hair, so neighbouring bubbles cannot overlap
    // and the outer two cannot spill past the lab table.
    var bubble = {
      lineH: 12 * scale,
      pad: 6 * scale,
      tail: 6 * scale,
      gap: 6 * scale,
      maxW: Math.max(72, pitch - 8 * scale)
    };
    // Fixed cost of a bubble regardless of how many lines it holds.
    var bubbleFixed = bubble.pad * 2 + bubble.tail + bubble.gap;
    // The station block below the band: the 6*scale inset, then cog, name,
    // reputation, coin, artifact badges, and the first row of the hand — the
    // tallest case, with badges. Keep in step with drawStation.
    var stationBlockH = cogSize * 1.22 + 106 * scale;
    // How many lines a full-length remark needs at this column width —
    // MEASURED in the bubble's own font rather than guessed, so the band is
    // never short (clipped text) and never hogs room it will not use. The
    // station band then grows to fit rather than eating into the cog block;
    // only a very short arena gets fewer lines, and then the tail ellipsizes.
    ctx.save();
    ctx.font = bubbleFont(scale);
    var charW = ctx.measureText(BUBBLE_FONT_SAMPLE).width /
      BUBBLE_FONT_SAMPLE.length;
    ctx.restore();
    var wantLines = Math.max(1, Math.ceil(
      MAX_SAY_LEN * charW * BUBBLE_RAGGED /
        Math.max(1, bubble.maxW - bubble.pad * 2)));
    var stationCap = mainH * 0.74;
    bubble.maxLines = Math.max(1,
      Math.min(wantLines, BUBBLE_LINES_CAP,
        Math.floor((stationCap - stationBlockH - bubbleFixed) / bubble.lineH)));
    bubble.band = bubble.maxLines * bubble.lineH + bubbleFixed;
    var stationH = Math.min(stationCap,
      Math.max(Math.max(96, mainH * (narrow ? 0.52 : 0.58)),
        stationBlockH + bubble.band));

    return {
      width: width, height: height, margin: margin, narrow: narrow,
      scale: scale, pitch: pitch, columns: columns,
      cogSize: cogSize, bubble: bubble,
      stationTop: mainY + 6 * scale + bubble.band,
      main: { x: mainX, y: mainY, w: mainW, h: mainH },
      stationH: stationH,
      bench: { x: mainX, y: mainY + stationH, w: mainW,
        h: mainH - stationH },
      board: { x: width - boardW - margin, y: mainY, w: boardW, h: mainH },
      strip: { x: margin, y: height - stripH - margin,
        w: width - 2 * margin, h: stripH }
    };
  }

  // ---- Drawing -------------------------------------------------------------

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    if (!w || !h) return;
    var seats = view.seats || [];
    var now = view.now || Date.now();
    var L = computeLayout(ctx, w, h);
    var fx = view.effects || {};

    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.45)";
    ctx.fillRect(0, 0, w, h);

    // Lab-table plate under the stations and the bench.
    ctx.save();
    ctx.fillStyle = STRIP;
    roundRect(ctx, L.main.x - 4, L.main.y, L.main.w + 8, L.main.h,
      10 * L.scale);
    ctx.fill();
    ctx.restore();

    for (var s = 0; s < 4; s++) {
      var seat = seats[s];
      if (!seat) continue;
      drawStation(ctx, images, L, view, s, seat, {
        pending: seat.pending && !view.done,
        now: now,
        sayAt: fx.sayAt ? fx.sayAt[s] : null,
        say: fx.lastSay ? fx.lastSay[s] : ""
      });
    }

    drawBench(ctx, L, view, now, fx);
    drawBoard(ctx, L, view, now, fx);
    drawTruthRow(ctx, L, view);
    drawGridStrip(ctx, L, view);
  }

  function drawStation(ctx, images, L, view, index, seat, opts) {
    var col = L.columns[index];
    var x = col.x;
    var top = L.stationTop;
    var size = L.cogSize;
    var color = seatColor(index);
    var sprite = images["soldier_" + color + "_front.png"];
    var cogY = top + size * 0.6;

    ctx.save();
    if (sprite && sprite.width) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(sprite, x - size / 2, cogY - size / 2, size, size);
    } else {
      ctx.fillStyle = COLOR_HEX[color];
      ctx.fillRect(x - size / 3, cogY - size / 3, size / 1.5, size / 1.5);
    }
    ctx.restore();

    if (opts.pending) {
      ctx.save();
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = 2.5;
      ctx.setLineDash([6, 5]);
      ctx.beginPath();
      ctx.arc(x, cogY, size * 0.62, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }

    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "alphabetic";
    ctx.font = "600 " + Math.round(12 * L.scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER;
    ctx.shadowColor = "rgba(0,0,0,0.8)";
    ctx.shadowBlur = 4;
    ctx.fillText(ellipsize(ctx, seat.name || "", L.pitch * 0.92), x,
      cogY + size * 0.62 + 12 * L.scale);
    ctx.font = "700 " + Math.round(21 * L.scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = (seat.reputation || 0) < 0 ? COLOR_HEX.red : AMBER;
    ctx.fillText(String(seat.reputation || 0), x,
      cogY + size * 0.62 + 34 * L.scale);
    ctx.font = "600 " + Math.round(10 * L.scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.fillText("reputation · " + (seat.coin || 0) + " coin", x,
      cogY + size * 0.62 + 46 * L.scale);
    ctx.restore();

    // Artifact badges.
    var badgeY = cogY + size * 0.62 + 58 * L.scale;
    var badges = [];
    if (seat.mortar) badges.push("MORTAR");
    if (seat.press) badges.push("PRESS");
    badges.forEach(function (label, i) {
      drawTag(ctx, x + (i - (badges.length - 1) / 2) * 46 * L.scale, badgeY,
        label, AMBER, L.scale);
    });

    // The hand: face-up ingredient cards, or just a count when small.
    var handY = badgeY + (badges.length ? 14 : 4) * L.scale;
    var hand = seat.hand || [];
    if (L.narrow || handY + 26 * L.scale > L.main.y + L.stationH) {
      ctx.save();
      ctx.textAlign = "center";
      ctx.font = "600 " + Math.round(10 * L.scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = GHOST;
      ctx.fillText((seat.handCount || hand.length || 0) + " cards", x, handY +
        10 * L.scale);
      ctx.restore();
    } else {
      var cardW = Math.min(L.pitch * 0.3, 52 * L.scale);
      var perRow = Math.max(1, Math.floor(L.pitch * 0.92 / (cardW + 3)));
      hand.forEach(function (name, i) {
        var row = Math.floor(i / perRow);
        var col2 = i % perRow;
        var count = Math.min(perRow, hand.length - row * perRow);
        var cx = x - (count * (cardW + 3) - 3) / 2 + col2 * (cardW + 3);
        drawCard(ctx, cx, handY + row * (16 * L.scale + 3), cardW,
          15 * L.scale, name, L.scale);
      });
    }

    if (opts.say) {
      var sayAge = typeof opts.sayAt === "number" ? opts.now - opts.sayAt :
        BUBBLE_HOLD_MS;
      var alpha = sayAge < BUBBLE_HOLD_MS ? 1 :
        Math.max(0.4, 1 - (sayAge - BUBBLE_HOLD_MS) / 4000);
      drawBubble(ctx, x, cogY - size * 0.6 - L.bubble.gap, opts.say, L,
        alpha);
    }
  }

  function drawCard(ctx, x, y, w, h, label, scale) {
    ctx.save();
    ctx.fillStyle = PAPER;
    ctx.strokeStyle = "rgba(42, 31, 22, 0.5)";
    ctx.lineWidth = 1;
    roundRect(ctx, x, y, w, h, 2);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = INK;
    ctx.font = "600 " + Math.round(8.5 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(ellipsize(ctx, label || "", w - 4), x + w / 2, y + h / 2 + 1);
    ctx.restore();
  }

  // The bench: the two cards on the table and the flask between them.
  function drawBench(ctx, L, view, now, fx) {
    var rect = L.bench;
    var cx = rect.x + rect.w / 2;
    var cy = rect.y + rect.h * 0.5;
    var scale = L.scale;
    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.42)";
    roundRect(ctx, rect.x + 2, rect.y, rect.w - 4, rect.h - 2, 8 * scale);
    ctx.fill();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.10)";
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.restore();

    var bench = view.bench;
    if (!bench) {
      ctx.save();
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.font = "700 " + Math.round(11 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = GHOST;
      ctx.fillText("THE LAB BENCH", cx, cy - 8 * scale);
      ctx.font = "600 " + Math.round(10 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillText(view.demand ? "the adventurer wants " + view.demand : "",
        cx, cy + 8 * scale);
      ctx.restore();
      return;
    }

    var age = typeof fx.benchAt === "number" ? now - fx.benchAt : BUBBLE_MS;
    var slide = Math.min(1, age / SLIDE_MS);
    var eased = 1 - Math.pow(1 - slide, 3);
    var resolved = age >= BUBBLE_MS;
    var cardW = Math.min(72 * scale, rect.w * 0.24);
    var cardH = 22 * scale;
    var gap = Math.min(96 * scale, rect.w * 0.3);

    drawCard(ctx, cx - gap - cardW / 2 - (1 - eased) * rect.w * 0.4,
      cy - cardH / 2, cardW, cardH, ingredientName(view, bench.a), scale);
    drawCard(ctx, cx + gap - cardW / 2 + (1 - eased) * rect.w * 0.4,
      cy - cardH / 2, cardW, cardH, ingredientName(view, bench.b), scale);

    drawFlask(ctx, cx, cy, scale * 1.15, resolved ? bench.potion : null,
      now, view);

    if (bench.secret) {
      // A paper screen: the audience sees the result, the rivals did not.
      ctx.save();
      ctx.globalAlpha = 0.24;
      ctx.fillStyle = PAPER;
      roundRect(ctx, cx - 46 * scale, cy - 40 * scale, 92 * scale,
        80 * scale, 5 * scale);
      ctx.fill();
      ctx.restore();
      drawTag(ctx, cx, cy - 46 * scale, "PRIVATE RESULT", PAPER_DIM, scale);
    }

    var actor = (view.seats || [])[bench.seat];
    if (actor) {
      ctx.save();
      ctx.textAlign = "center";
      ctx.font = "600 " + Math.round(10 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = COLOR_HEX[seatColor(bench.seat)];
      ctx.fillText(actor.name || "", cx, rect.y + rect.h - 6 * scale);
      ctx.restore();
      if (actor.result === "poisoned") {
        drawTag(ctx, cx, cy + 46 * scale, "POISONED −2", COLOR_HEX.red,
          scale);
      } else if (actor.result === "glowed") {
        drawTag(ctx, cx, cy + 46 * scale, "TRIUMPH +1", COLOR_HEX.green,
          scale);
      } else if (actor.result === "hit") {
        drawTag(ctx, cx, cy + 46 * scale, "SOLD +6 COIN", AMBER, scale);
      } else if (actor.result === "miss") {
        drawTag(ctx, cx, cy + 46 * scale, "NOT WHAT THEY WANTED",
          PAPER_DIM, scale);
      } else if (actor.result === "burned") {
        drawTag(ctx, cx, cy + 46 * scale, "SEAL BURNED", COLOR_HEX.red,
          scale);
      } else if (actor.result === "survived") {
        drawTag(ctx, cx, cy + 46 * scale, "THE SEAL STANDS", AMBER, scale);
      }
    }

    // The acting seat's whole grid, beside the bench.
    if (!L.narrow && actor && actor.grid) {
      drawSeatMatrix(ctx, rect.x + 6, rect.y + 6,
        Math.min(rect.w * 0.24, 130 * scale), rect.h - 12, view, bench.seat,
        scale);
    }
  }

  function drawFlask(ctx, cx, cy, scale, potion, now, view) {
    var w = 30 * scale;
    var h = 40 * scale;
    ctx.save();
    ctx.strokeStyle = PAPER;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(cx - w * 0.22, cy - h * 0.55);
    ctx.lineTo(cx - w * 0.22, cy - h * 0.15);
    ctx.lineTo(cx - w * 0.5, cy + h * 0.45);
    ctx.lineTo(cx + w * 0.5, cy + h * 0.45);
    ctx.lineTo(cx + w * 0.22, cy - h * 0.15);
    ctx.lineTo(cx + w * 0.22, cy - h * 0.55);
    ctx.closePath();
    ctx.stroke();
    if (potion) {
      var hex = POTION_HEX[potion] || GHOST;
      ctx.fillStyle = rgba(hex, 0.75);
      ctx.fill();
      ctx.fillStyle = PAPER;
      ctx.font = "700 " + Math.round(20 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      if (potion === "MUD") {
        ctx.font = "700 " + Math.round(11 * scale) +
          "px 'rajdhani', system-ui, sans-serif";
        ctx.fillText("MUD", cx, cy + h * 0.16);
      } else {
        ctx.fillText(potion.slice(-1) === "+" ? "+" : "−", cx, cy + h * 0.16);
      }
      ctx.restore();
      drawTag(ctx, cx, cy + h * 0.72, potion, hex, scale);
      return;
    }
    // Bubbling.
    var t = (now % 900) / 900;
    ctx.fillStyle = rgba(PAPER, 0.16);
    ctx.fill();
    for (var i = 0; i < 5; i++) {
      var phase = (t + i * 0.2) % 1;
      ctx.fillStyle = rgba(PAPER, 0.5 * (1 - phase));
      ctx.beginPath();
      ctx.arc(cx + Math.sin((i + phase) * 5) * w * 0.22,
        cy + h * 0.4 - phase * h * 0.55, 2.2 * scale, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.restore();
    void view;
  }

  // The theory board: one wax-sealed card per published ingredient.
  function drawBoard(ctx, L, view, now, fx) {
    var rect = L.board;
    var scale = L.scale;
    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.5)";
    roundRect(ctx, rect.x, rect.y, rect.w, rect.h, 8 * scale);
    ctx.fill();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.12)";
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.font = "700 " + Math.round(10 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillText("THE THEORY BOARD", rect.x + 7, rect.y + 5);
    ctx.restore();

    var seals = view.seals || [];
    if (!seals.length) {
      ctx.save();
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.font = "600 " + Math.round(10 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = GHOST;
      ctx.fillText("no seal pinned yet", rect.x + rect.w / 2,
        rect.y + rect.h / 2);
      ctx.restore();
      return;
    }
    // At the exhibition the truth row takes the bottom of the board, so the
    // seals stack above it and every verdict tag stays visible.
    var chemistry = view.chemistry || [];
    var revealed = chemistry.length === 8;
    var reserve = revealed ? truthRowH(L) + 6 : 0;
    var top = rect.y + 20 * scale;
    var cardH = Math.max(30, Math.min(58 * scale,
      (rect.h - 26 * scale - reserve) / seals.length));
    seals.forEach(function (seal, i) {
      // Burned seals settled at the burn and are not re-scored; every other
      // standing seal is opened against the truth.
      var verdict = null;
      if (revealed && seal.status !== "burned") {
        verdict = chemistry[seal.ingredient] === seal.claim;
      }
      drawSeal(ctx, rect.x + 6, top + i * (cardH + 3), rect.w - 12,
        cardH - 1, seal, view, scale, L.narrow,
        fx.burnAt ? fx.burnAt[seal.ingredient] : null, now, verdict);
    });
  }

  // The endcard reveal: the eight true signatures, drawn once, large, in a
  // row under the board at the exhibition frame.
  function truthRowH(L) {
    return Math.max(24, Math.min(38 * L.scale, L.main.h * 0.16));
  }

  function drawTruthRow(ctx, L, view) {
    var chemistry = view.chemistry || [];
    if (chemistry.length !== 8) return;
    var scale = L.scale;
    var h = truthRowH(L);
    var x = L.main.x;
    var w = L.board.x + L.board.w - x;
    var y = L.main.y + L.main.h - h;
    var cellW = w / 8;
    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.88)";
    roundRect(ctx, x, y, w, h, 6 * scale);
    ctx.fill();
    ctx.strokeStyle = rgba(AMBER, 0.55);
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.textAlign = "center";
    for (var i = 0; i < 8; i++) {
      var cx = x + cellW * (i + 0.5);
      ctx.textBaseline = "top";
      ctx.font = "700 " + Math.round(8.5 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = PAPER_DIM;
      ctx.fillText(ellipsize(ctx, ingredientName(view, i), cellW - 4), cx,
        y + 3);
      ctx.textBaseline = "bottom";
      ctx.font = "700 " +
        Math.round(Math.max(9, Math.min(16 * scale, cellW / 3.6))) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = AMBER;
      ctx.fillText(signatureName(view, chemistry[i]), cx, y + h - 3);
    }
    ctx.restore();
  }

  function drawSeal(ctx, x, y, w, h, seal, view, scale, narrow, burnAt, now,
      verdict) {
    var burned = seal.status === "burned";
    var tilt = burned ? 0.05 : 0;
    ctx.save();
    ctx.translate(x + w / 2, y + h / 2);
    ctx.rotate(tilt);
    ctx.translate(-(x + w / 2), -(y + h / 2));
    ctx.fillStyle = burned ? CHAR : PAPER;
    ctx.strokeStyle = burned ? "rgba(224, 82, 58, 0.7)" :
      "rgba(42, 31, 22, 0.4)";
    ctx.lineWidth = 1;
    roundRect(ctx, x, y, w, h, 3);
    ctx.fill();
    ctx.stroke();

    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillStyle = burned ? PAPER_DIM : INK;
    if (!narrow) {
      ctx.font = "700 " + Math.round(10 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillText(ellipsize(ctx, ingredientName(view, seal.ingredient),
        w - 20 * scale), x + 5, y + 4);
    }
    // The claim, as three coloured dots with their signs.
    var text = seal.claimText || signatureName(view, seal.claim);
    var dotY = y + (narrow ? h * 0.4 : 20 * scale);
    for (var a = 0; a < 3; a++) {
      var cx = x + 9 * scale + a * 15 * scale;
      ctx.fillStyle = burned ? GHOST : ASPECT_HEX[a];
      ctx.beginPath();
      ctx.arc(cx, dotY, 4.5 * scale, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = PAPER;
      ctx.font = "700 " + Math.round(9 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(text.charAt(a * 2 + 1) === "+" ? "+" : "−", cx, dotY + 1);
    }
    // The author's wax seal, in their colour.
    ctx.fillStyle = burned ? CHAR : WAX;
    ctx.strokeStyle = COLOR_HEX[seatColor(seal.author)];
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.arc(x + w - 12 * scale, dotY, 6.5 * scale, 0, Math.PI * 2);
    ctx.fill();
    ctx.stroke();
    // Endorser pips.
    (seal.endorsers || []).forEach(function (endorser, i) {
      ctx.fillStyle = COLOR_HEX[seatColor(endorser)];
      ctx.fillRect(x + 5 + i * 7 * scale, y + h - 6 * scale, 5 * scale,
        3.5 * scale);
    });
    if (seal.vindications > 0 && !burned) {
      ctx.fillStyle = AMBER;
      ctx.font = "700 " + Math.round(8 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "right";
      ctx.textBaseline = "bottom";
      ctx.fillText("\u2740 survived " + seal.vindications, x + w - 4,
        y + h - 2);
    }
    ctx.restore();
    if (burned) {
      var names = view.seatNames || [];
      drawTag(ctx, x + w / 2, y + h / 2,
        "BURNED BY " + String(names[seal.burnedBy] || "?").toUpperCase(),
        COLOR_HEX.red, scale);
    } else if (verdict === true) {
      drawTag(ctx, x + w / 2, y + h / 2, "TRUE +5", AMBER, scale);
    } else if (verdict === false) {
      drawTag(ctx, x + w / 2, y + h / 2, "FALSE \u22126", COLOR_HEX.red,
        scale);
    }
    void burnAt;
    void now;
  }

  // The hole-cam: four rows (one per seat) x eight columns (one per
  // ingredient). A cell shows how many signatures that seat still thinks
  // possible; a solved cell shows the signature itself.
  function drawGridStrip(ctx, L, view) {
    var rect = L.strip;
    var scale = L.scale;
    var seats = view.seats || [];
    var chemistry = view.chemistry || [];
    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.55)";
    roundRect(ctx, rect.x, rect.y, rect.w, rect.h, 6 * scale);
    ctx.fill();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.12)";
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.restore();

    var labelW = Math.min(96 * scale, rect.w * 0.2);
    var headH = 13 * scale;
    var rowH = (rect.h - headH - 4) / 4;

    if (L.narrow) {
      // Small screens: just "solved / chemistries left" per seat.
      ctx.save();
      ctx.textAlign = "left";
      ctx.textBaseline = "middle";
      seats.forEach(function (seat, i) {
        var y = rect.y + headH + rowH * (i + 0.5);
        ctx.font = "600 " + Math.round(10 * scale) +
          "px 'rajdhani', system-ui, sans-serif";
        ctx.fillStyle = COLOR_HEX[seatColor(i)];
        ctx.fillText(ellipsize(ctx, seat.name || "", rect.w * 0.4),
          rect.x + 6, y);
        ctx.fillStyle = PAPER;
        ctx.fillText((seat.solved || 0) + " solved · " +
          (seat.chemistries || 0) + " left", rect.x + rect.w * 0.45, y);
      });
      ctx.font = "700 " + Math.round(9 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = PAPER_DIM;
      ctx.textBaseline = "top";
      ctx.fillText("WHO ACTUALLY KNOWS", rect.x + 6, rect.y + 3);
      ctx.restore();
      return;
    }

    var cellW = (rect.w - labelW - 8) / 8;
    ctx.save();
    ctx.font = "700 " + Math.round(8.5 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    for (var c = 0; c < 8; c++) {
      ctx.fillText(ellipsize(ctx, ingredientName(view, c), cellW - 2),
        rect.x + labelW + cellW * (c + 0.5), rect.y + 3);
    }
    ctx.restore();

    seats.forEach(function (seat, i) {
      var y = rect.y + headH + rowH * i;
      ctx.save();
      ctx.textAlign = "left";
      ctx.textBaseline = "middle";
      ctx.font = "600 " + Math.round(9.5 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = COLOR_HEX[seatColor(i)];
      ctx.fillText(ellipsize(ctx, seat.name || "", labelW - 34 * scale),
        rect.x + 5, y + rowH / 2);
      ctx.fillStyle = PAPER_DIM;
      ctx.font = "600 " + Math.round(8.5 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "right";
      ctx.fillText(String(seat.chemistries || 0), rect.x + labelW - 4,
        y + rowH / 2);
      ctx.restore();

      var grid = seat.grid || [];
      var published = seat.published || [];
      for (var c2 = 0; c2 < 8; c2++) {
        var cell = grid[c2] || [];
        var cx = rect.x + labelW + cellW * c2;
        var solvedCell = cell.length === 1;
        var bluff = published.indexOf(c2) >= 0 && cell.length > 1;
        ctx.save();
        ctx.fillStyle = solvedCell ? rgba(COLOR_HEX[seatColor(i)], 0.28) :
          "rgba(242, 232, 216, 0.05)";
        roundRect(ctx, cx + 1, y + 1, cellW - 2, rowH - 2, 2);
        ctx.fill();
        if (bluff) {
          ctx.strokeStyle = COLOR_HEX.red;
          ctx.lineWidth = 1.5;
          ctx.stroke();
        }
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        if (chemistry.length === 8) {
          ctx.font = "700 " + Math.round(8.5 * scale) +
            "px 'rajdhani', system-ui, sans-serif";
          ctx.fillStyle = AMBER;
          ctx.fillText(signatureName(view, chemistry[c2]), cx + cellW / 2,
            y + rowH / 2);
        } else if (solvedCell) {
          ctx.font = "700 " + Math.round(8.5 * scale) +
            "px 'rajdhani', system-ui, sans-serif";
          ctx.fillStyle = PAPER;
          ctx.fillText(signatureName(view, cell[0]), cx + cellW / 2,
            y + rowH / 2);
        } else {
          ctx.font = "700 " + Math.round(11 * scale) +
            "px 'rajdhani', system-ui, sans-serif";
          ctx.fillStyle = bluff ? COLOR_HEX.red : PAPER_DIM;
          ctx.fillText(String(cell.length), cx + cellW / 2, y + rowH / 2);
        }
        if (bluff) {
          ctx.font = "700 " + Math.round(7 * scale) +
            "px 'rajdhani', system-ui, sans-serif";
          ctx.fillStyle = COLOR_HEX.red;
          ctx.textBaseline = "bottom";
          ctx.fillText("BLUFF?", cx + cellW / 2, y + rowH - 1);
        }
        ctx.restore();
      }
    });
  }

  function drawSeatMatrix(ctx, x, y, w, h, view, seatIndex, scale) {
    var seat = (view.seats || [])[seatIndex];
    if (!seat || !seat.grid) return;
    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.55)";
    roundRect(ctx, x, y, w, h, 4);
    ctx.fill();
    ctx.font = "700 " + Math.round(8 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = COLOR_HEX[seatColor(seatIndex)];
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillText(ellipsize(ctx, (seat.name || "") + " KNOWS", w - 6), x + 3,
      y + 3);
    var rowH = (h - 14) / 8;
    for (var r = 0; r < 8; r++) {
      var cell = seat.grid[r] || [];
      ctx.font = "600 " + Math.round(7.5 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = cell.length === 1 ? PAPER : PAPER_DIM;
      ctx.fillText(ellipsize(ctx,
        ingredientName(view, r) + " " +
        (cell.length === 1 ? signatureName(view, cell[0]) :
          cell.length + " left"), w - 6), x + 3, y + 12 + r * rowH);
    }
    ctx.restore();
  }

  function drawTag(ctx, x, y, text, accent, scale) {
    ctx.save();
    ctx.font = "700 " + Math.round(9 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    var label = String(text).toUpperCase();
    var pad = 5 * scale;
    var bw = ctx.measureText(label).width + pad * 2;
    var bh = 14 * scale;
    ctx.fillStyle = "rgba(242, 232, 216, 0.95)";
    ctx.strokeStyle = accent;
    ctx.lineWidth = 2;
    roundRect(ctx, x - bw / 2, y - bh / 2, bw, bh, 4 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(label, x, y + scale * 0.5);
    ctx.restore();
  }

  // A word wider than the line gets hard-broken rather than ellipsized, so a
  // long ingredient run or a pasted signature string loses nothing.
  function breakWord(ctx, word, maxWidth) {
    var parts = [];
    var head = "";
    for (var i = 0; i < word.length; i++) {
      if (head && ctx.measureText(head + word[i]).width > maxWidth) {
        parts.push(head);
        head = "";
      }
      head += word[i];
    }
    if (head) parts.push(head);
    return parts;
  }

  function wrapLines(ctx, text, maxWidth, maxLines) {
    var words = [];
    String(text).split(/\s+/).forEach(function (word) {
      if (!word) return;
      if (ctx.measureText(word).width <= maxWidth) words.push(word);
      else words = words.concat(breakWord(ctx, word, maxWidth));
    });
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = probe;
      }
    });
    if (line) lines.push(line);
    var overflow = lines.length > maxLines;
    lines = lines.slice(0, maxLines);
    if (overflow && lines.length) {
      lines[lines.length - 1] = ellipsize(ctx, lines[lines.length - 1] + "…",
        maxWidth);
    }
    return lines.map(function (l) { return ellipsize(ctx, l, maxWidth); });
  }

  // Bubbles hang off the BOTTOM edge given: `bottom` is where the tail's tip
  // lands, and the body grows upward into the band the layout reserved for it
  // (L.bubble.band), so a long remark never runs off the top of the canvas.
  function drawBubble(ctx, x, bottom, text, L, alpha) {
    var scale = L.scale;
    var B = L.bubble;
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.font = bubbleFont(scale);
    var pad = B.pad;
    var lineH = B.lineH;
    var lines = wrapLines(ctx, text, B.maxW - pad * 2, B.maxLines);
    var bw = 0;
    lines.forEach(function (l) { bw = Math.max(bw, ctx.measureText(l).width); });
    bw += pad * 2;
    var bh = lines.length * lineH + pad * 2 - 2;
    var y = bottom - bh - B.tail;
    ctx.shadowColor = "rgba(0,0,0,0.6)";
    ctx.shadowBlur = 5;
    ctx.fillStyle = PAPER;
    roundRect(ctx, x - bw / 2, y, bw, bh, 5 * scale);
    ctx.fill();
    ctx.shadowColor = "transparent";
    ctx.beginPath();
    ctx.moveTo(x - 5 * scale, y + bh);
    ctx.lineTo(x, y + bh + B.tail);
    ctx.lineTo(x + 5 * scale, y + bh);
    ctx.closePath();
    ctx.fill();
    ctx.fillStyle = INK;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    lines.forEach(function (l, i) {
      ctx.fillText(l, x - bw / 2 + pad, y + pad + i * lineH);
    });
    ctx.restore();
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous table names ("Sprocket", "Gizmo");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  function meta(view) {
    return {
      ingredients: (view && view.ingredients) || INGREDIENTS,
      signatures: (view && view.signatures) || SIGNATURES
    };
  }

  function ing(m, index) {
    return (m.ingredients[index] !== undefined) ? m.ingredients[index] : "?";
  }
  function sig(m, index) {
    return (m.signatures[index] !== undefined) ? m.signatures[index] : "?";
  }

  // In words a casual spectator can read: never "i0", "p3" or "sig#5".
  function describeEvent(event, nameMap, ctx, m) {
    function name(i) {
      return clampName(nameMap.seat(i));
    }
    switch (event.kind) {
      case "start":
        return "The academy opens — eight ingredients, a secret chemistry, " +
          "and four cogs with three cards each.";
      case "round":
        var royal = (event.royalties || []).reduce(function (a, b) {
          return a + b;
        }, 0);
        return "Round " + ((event.round || 0) + 1) + " — the adventurer " +
          "wants " + (event.demand || "?") + "." +
          (royal ? " Royalties paid: " + royal + " coin." : "");
      case "phase":
        return event.phase === "lab" ?
          "The laboratory opens: private science." :
          "The market opens: seals, sales and demonstrations.";
      case "act":
        return describeAct(event, nameMap, ctx, m, name);
      case "exhibition":
        var parts = (event.verdicts || []).map(function (v) {
          return ing(m, v.ingredient) + " " + (v.claimText || sig(m, v.claim)) +
            (v["true"] ? " TRUE: " + name(v.author) + " +5" :
              " FALSE: " + name(v.author) + " −6") +
            ((v.endorsers || []).length ? ", endorsers " +
              (v["true"] ? "+2" : "−3") + " each" : "");
        });
        return "EXHIBITION — " + (parts.length ? parts.join(". ") :
          "not one seal was left standing.");
      case "end":
        var line = "Final — " + (ctx.standings || "no scores") + " over " +
          (event.round || 0) + " rounds.";
        if (event.text === "deadline") {
          line += " Episode deadline — the academy closed early; the " +
            "exhibition was held after " + (event.round || 0) + " rounds.";
        }
        return line;
      default: return JSON.stringify(event);
    }
  }

  function describeAct(event, nameMap, ctx, m, name) {
    var who = name(event.seat);
    var a = event.a >= 0 ? ing(m, event.a) : "";
    var b = event.b >= 0 ? ing(m, event.b) : "";
    var result = event.result || "";
    if (result.indexOf("rejected:") === 0) {
      return who + " tried to " + event.action + " but was too late (" +
        result.slice("rejected:".length).replace(/_/g, " ") + "). " + who +
        " passes (+1 coin).";
    }
    switch (event.action) {
      case "forage":
        var drawn = (event.draws || []).map(function (d) { return ing(m, d); });
        return who + " forages and draws " + drawn.join(" + ") + ".";
      case "test_student":
        return who + " tests " + a + " + " + b + " on a student — result " +
          "sealed (only " + who + " saw it).";
      case "test_self":
        var klass = event.potion === "MUD" ? "mud" :
          (String(event.potion).slice(-1) === "+" ? "positive" : "negative");
        return who + " drinks " + a + " + " + b + " — " + klass + "." +
          (result === "poisoned" ? " Poisoned, −2 reputation." :
            result === "glowed" ? " A triumph, +1 reputation." : "");
      case "transmute":
        return who + " transmutes " + a + " for 2 coin.";
      case "sell":
        return who + " sells " + a + " + " + b + ": " + event.potion +
          (result === "hit" ?
            " — exactly what the adventurer wanted. +1 reputation, +6 coin." :
            " — the adventurer wanted " + (ctx.demand || "something else") +
            ". −1 reputation, +2 coin.");
      case "publish":
        return who + " publishes: " + a + " is " + sig(m, event.signature) +
          ". Seal pinned, +" + (event.repDelta || 2) + " reputation.";
      case "endorse":
        return who + " endorses " + name(event.target) + "'s " + a + " seal.";
      case "debunk":
        if (result === "burned") {
          return who + " debunks " + name(event.target) + "'s " + a +
            " with " + b + " → " + event.potion +
            ", not what the seal predicted. SEAL BURNED. " +
            name(event.target) + " −4, " + who + " +3.";
        }
        return who + " debunks " + name(event.target) + "'s " + a + " with " +
          b + " → " + event.potion + ", exactly as claimed. The seal " +
          "stands. " + who + " −2.";
      case "buy":
        return who + " buys the " +
          (event.artifact === "press" ? "Printing Press" : "Magic Mortar") +
          ".";
      default:
        return who + " passes (+1 coin).";
    }
  }

  function feedClass(event) {
    if (event.kind === "act") {
      var result = event.result || "";
      if (result.indexOf("rejected:") === 0) return "feed-reject";
      if (event.action === "publish") return "feed-publish";
      if (event.action === "debunk") {
        return result === "burned" ? "feed-burn" : "feed-debunk";
      }
      if (event.action === "sell") return "feed-sell";
      if (result === "poisoned") return "feed-poison";
      if (event.action === "test_self" || event.action === "test_student") {
        return "feed-test";
      }
      return "feed-act";
    }
    if (event.kind === "exhibition") return "feed-exhibit";
    if (event.kind === "end") return "feed-rwin";
    return "feed-" + event.kind;
  }

  function blockHead(event, lastRound) {
    if (event.kind === "start") return "SETUP";
    if (event.kind === "exhibition") return "EXHIBITION";
    if (event.kind === "end") return "FINAL";
    var round = "ROUND " + ((event.round === undefined ? lastRound :
      event.round) + 1);
    if (event.kind === "phase" || event.kind === "act") {
      return round + " · " + String(event.phase || "").toUpperCase();
    }
    return round;
  }

  // Renders the full transcript grouped into one section per round/phase.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex, view) {
    if (!element) return;
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var m = meta(view);
    var html = "";
    var lastBlock = null;
    var lastRound = 0;
    var ctx = { demand: "", standings: "" };
    if (view && view.seats && view.seats.length) {
      ctx.standings = view.seats.map(function (seat, i) {
        return clampName(nameMap.seat(i)) + " " + fixed(seat.score, 1);
      }).join(", ");
    }
    var lastNotes = {};
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      if (event.kind === "round") {
        ctx.demand = event.demand;
        lastRound = event.round;
      }
      var block = blockHead(event, lastRound);
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + block + "</div>";
        lastBlock = block;
      }
      var text = describeEvent(event, nameMap, ctx, m);
      var cls = "feed-line " + feedClass(event) +
        (event.kind === "act" ? " seat" + (event.seat % COLORS.length) : "") +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' + escapeHtml(text) + "</div>";
      if (event.kind === "act" && event.say) {
        html += '<div class="feed-line feed-say' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + " says: \"" +
            nameMap.text(event.say) + "\"") + "</div>";
      }
      if (event.kind === "act" && event.text &&
          event.text !== lastNotes[event.seat]) {
        lastNotes[event.seat] = event.text;
        html += '<div class="feed-line feed-notes' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + " notes: " +
            nameMap.text(event.text)) + "</div>";
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return String(text).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects:
  // when the bench last changed (the flask bubbles then resolves), each
  // seat's last remark, and when each seal burned (the gong).
  function makeEffects() {
    var seen = 0;
    var benchAt = null;
    var sayAt = [null, null, null, null];
    var lastSay = ["", "", "", ""];
    var burnAt = {};
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only the
      // newest event gets to animate.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "phase" || event.kind === "round") {
            benchAt = null;
          } else if (event.kind === "act") {
            if (["test_student", "test_self", "sell", "debunk"]
                .indexOf(event.action) >= 0) {
              benchAt = animate ? now : now - 5000;
            }
            if (event.result === "burned") {
              burnAt[event.a] = animate ? now : null;
            }
            if (event.say) {
              lastSay[event.seat] = event.say;
              sayAt[event.seat] = animate ? now : null;
            }
          }
        }
      },
      reset: function () {
        seen = 0; benchAt = null; burnAt = {};
        sayAt = [null, null, null, null];
        lastSay = ["", "", "", ""];
      },
      view: function () {
        return { effects: { benchAt: benchAt, sayAt: sayAt.slice(),
          lastSay: lastSay.slice(), burnAt: burnAt } };
      }
    };
  }

  // ---- Scorebug, header, labbar, endscreen ---------------------------------

  function leaderOf(state) {
    var seats = (state && state.seats) || [];
    var best = -1;
    seats.forEach(function (seat, i) {
      if (best < 0 || (seat.score || 0) > (seats[best].score || 0)) best = i;
    });
    return best;
  }

  function matchHeader(state, config, nameMap) {
    if (!state) return "";
    var total = state.rounds || (config && config.rounds) || 0;
    if (state.gameDone || state.done) {
      var best = leaderOf(state);
      if (best < 0) return "FINAL";
      var who = nameMap ? nameMap.seat(best) : state.seats[best].name;
      return "FINAL · " + String(who).toUpperCase() + " " +
        fixed(state.seats[best].score, 1);
    }
    if (state.exhibited) return "EXHIBITION";
    if (!state.started) return "THE ACADEMY · " + total + " ROUNDS";
    var waiting = (state.seats || []).filter(function (s) {
      return s.pending;
    }).length;
    return "ROUND " + ((state.round || 0) + 1) + " / " + total + " · " +
      String(state.phase || "").toUpperCase() + " · " +
      (waiting ? "WAITING ON " + waiting : "MOVES IN");
  }

  function sealPips(state, index) {
    var pips = "";
    (state.seals || []).forEach(function (seal) {
      if (seal.author !== index) return;
      pips += '<span class="plate-pip' +
        (seal.status === "burned" ? " charred" : "") + '"></span>';
    });
    return pips ? '<span class="plate-seals">' + pips + "</span>" : "";
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      html += '<div class="plate ' + seatColor(index) + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (seat.pending && !state.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-score plate-rep">' +
        escapeHtml(String(seat.reputation === undefined ? 0 :
          seat.reputation)) + "</span>" +
        '<span class="plate-label">rep</span>' +
        '<span class="plate-coin">' + (seat.coin || 0) + "c</span>" +
        sealPips(state, index) +
        '<span class="plate-solved">' + (seat.solved || 0) +
        " solved</span>" +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function updateLabBar(element, state) {
    if (!element || !state) return;
    var standing = 0;
    var burned = 0;
    (state.seals || []).forEach(function (seal) {
      if (seal.status === "burned") burned += 1; else standing += 1;
    });
    var best = null;
    (state.seats || []).forEach(function (seat) {
      if (best === null || (seat.chemistries || 0) < best) {
        best = seat.chemistries || 0;
      }
    });
    var round = "R" + ((state.round || 0) + 1) + "/" + (state.rounds || 0);
    var text;
    if (window.innerWidth < 420) {
      text = round + " · WANTS " + (state.demand || "?") + " · " +
        standing + " SEALS";
    } else {
      text = "ROUND " + ((state.round || 0) + 1) + "/" + (state.rounds || 0) +
        " · ADVENTURER WANTS " + (state.demand || "?") +
        " · SEALS " + standing + " STANDING / " + burned + " BURNED" +
        (best === null ? "" : " · BEST GRID " + best + " CHEMISTRIES LEFT");
    }
    if (element.textContent !== text) element.textContent = text;
  }

  function reasonLine(results) {
    switch (results.reason) {
      case "deadline":
        return "episode deadline: the exhibition was held after " +
          (results.rounds || 0) + " of " +
          (results.maxRounds || results.rounds || 0) + " rounds";
      default: return "";
    }
  }

  // Final standings overlay: verdict up top, ranked rows below.
  function updateEndscreen(container, results, show, nameMap, extra) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) { return (scores[b] || 0) - (scores[a] || 0); });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (scores[i] || 0) === (scores[topIndex] || 0);
    });
    var verdictColor = !level && topIndex >= 0 ? seatColor(topIndex) : "";
    var verdict = !level && topIndex >= 0 ?
      escapeHtml(names[topIndex]) + " MADE THE REPUTATION" : "ALL LEVEL";
    var reason = reasonLine(results);
    var seals = (extra && extra.seals) || 0;
    var burned = (extra && extra.burned) || 0;
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.rounds || 0) + " ROUND" +
      ((results.rounds || 0) === 1 ? "" : "S") + " · " + seals + " SEAL" +
      (seals === 1 ? "" : "S") + " · " + burned + " BURNED</div>" +
      '<div class="end-verdict ' + verdictColor + '">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">reputation</span>' +
      '<span class="end-head">coin</span>' +
      '<span class="end-head">published</span>' +
      '<span class="end-head">true</span>' +
      '<span class="end-head">false</span>' +
      '<span class="end-head">score</span>';
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        cell((results.reputation || [])[i] || 0) +
        cell((results.coin || [])[i] || 0) +
        cell((results.published || [])[i] || 0) +
        cell((results.trueTheories || [])[i] || 0) +
        cell((results.falseTheories || [])[i] || 0) +
        cell(fixed(scores[i], 1));
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  function sealTally(events) {
    var seals = 0;
    var burned = 0;
    (events || []).forEach(function (event) {
      if (event.kind !== "act") return;
      if (event.action === "publish" &&
          String(event.result || "").indexOf("rejected:") !== 0) {
        seals += 1;
      }
      if (event.result === "burned") burned += 1;
    });
    return { seals: seals, burned: burned };
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- Drivers -------------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = applyNames(state.seats, nameMap);
    view.seatNames = view.seats.map(function (s) { return s.name; });
    view.seals = state.seals || [];
    view.publicFacts = state.publicFacts || [];
    view.bench = state.bench || null;
    view.ingredients = state.ingredients || INGREDIENTS;
    view.signatures = state.signatures || SIGNATURES;
    view.round = state.round || 0;
    view.rounds = state.rounds || 0;
    view.roundsPlayed = state.roundsPlayed || 0;
    view.phase = state.phase || "";
    view.demand = state.demand || "";
    view.chemistry = state.chemistry || [];
    view.started = !!state.started;
    view.exhibited = !!state.exhibited;
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  // A redacted player frame ({you:{...},table:[...]}) becomes a four-seat
  // state with the own seat filled in so the same scene draws.
  function playerFrameToState(data) {
    if (data.seats) return data;
    var seats = (data.table || []).map(function (entry, i) {
      return {
        name: entry.name || ("Seat " + i),
        coin: entry.coin || 0,
        reputation: entry.reputation || 0,
        score: entry.score || 0,
        handCount: entry.handCount || 0,
        hand: [],
        mortar: !!entry.mortar,
        press: !!entry.press,
        published: entry.published || [],
        grid: null,
        chemistries: 0,
        solved: 0,
        pending: false
      };
    });
    while (seats.length < 4) {
      seats.push({ name: "Seat " + seats.length, coin: 0, reputation: 0,
        score: 0, handCount: 0, hand: [], published: [], grid: null });
    }
    if (typeof data.slot === "number" && data.you) {
      var own = seats[data.slot];
      own.hand = data.you.hand || [];
      own.grid = data.you.grid || null;
      own.chemistries = data.you.chemistries || 0;
      own.notes = data.you.notes || "";
      own.solved = (data.you.grid || []).filter(function (cell) {
        return cell.length === 1;
      }).length;
    }
    return {
      seats: seats, seals: data.seals || [],
      publicFacts: data.publicFacts || [], bench: null,
      ingredients: INGREDIENTS, signatures: SIGNATURES,
      round: data.round || 0, rounds: data.rounds || 0,
      roundsPlayed: data.round || 0, phase: data.phase || "",
      demand: data.demand || "", chemistry: [],
      started: !!data.started, exhibited: false,
      gameDone: !!data.done, reason: data.reason || "", events: []
    };
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, labbar, endscreen,
    //           assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var nameMap = makeNameMap([], null);
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = playerFrameToState(data);
            if (latest) {
              nameMap = makeNameMap(seatNames(latest), latest.policyNames);
              effects.absorb(latest.events || []);
              renderFeed(options.feed, latest.events || [], nameMap,
                undefined, latest);
              if (options.clock) {
                options.clock.textContent = matchHeader(latest, latest,
                  nameMap);
              }
              updateScorebug(options.scorebug, latest, nameMap);
              updateLabBar(options.labbar, latest);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap,
                sealTally(latest && latest.events || []));
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      (function frame() {
        if (latest) {
          var view = stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone)
          });
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // One beat marker: a labelled, clickable button that seeks to its event.
  // Named markChemBeat (never markBeat) so no page-level alias assignment
  // can shadow it.
  function markChemBeat(container, index, total, kind, seat, label, onSeek) {
    var marker = document.createElement("button");
    marker.type = "button";
    marker.className = "beat-marker " + kind +
      (typeof seat === "number" && seat >= 0 ?
        " seat" + (seat % COLORS.length) : "");
    marker.style.left = ((index + 1) / total * 100) + "%";
    marker.title = label;
    marker.setAttribute("aria-label", label);
    marker.onclick = function (evt) {
      evt.stopPropagation();
      onSeek(index + 1);
    };
    container.appendChild(marker);
    return marker;
  }

  function beatKind(event) {
    if (event.kind === "exhibition") return "exhibition";
    if (event.kind === "end") return "end";
    if (event.kind !== "act") return "";
    if (String(event.result || "").indexOf("rejected:") === 0) return "trade";
    switch (event.action) {
      case "publish": return "publish";
      case "debunk": return "debunk";
      case "sell": return "sell";
      case "test_student":
      case "test_self": return "test";
      default: return "trade";
    }
  }

  function beatLabel(event, nameMap, m) {
    var round = "R" + ((event.round || 0) + 1);
    if (event.kind === "exhibition") return "EXHIBITION";
    if (event.kind === "end") return "FINAL";
    var who = clampName(nameMap.seat(event.seat));
    var a = event.a >= 0 ? ing(m, event.a) : "";
    switch (beatKind(event)) {
      case "publish":
        return round + " · PUBLISH · " + who + " claims " + a + " " +
          sig(m, event.signature);
      case "debunk":
        return round + " · DEBUNK · " + who +
          (event.result === "burned" ? " burns " : " fails against ") +
          clampName(nameMap.seat(event.target)) + "'s seal";
      case "sell":
        return round + " · SELL · " + who +
          (event.result === "hit" ? " hits " : " misses with ") +
          event.potion;
      case "test":
        return round + " · TEST · " + who +
          (event.action === "test_self" ? " drinks it" : " pays a student");
      default:
        return round + " · " + String(event.action || "").toUpperCase() +
          " · " + who;
    }
  }

  // Scrubber: a click/drag-to-seek track with one span per phase, a
  // separator each round, and one labelled beat button per notable event.
  function buildScrub(container, events, onSeek, nameMap, view) {
    container.innerHTML = "";
    var m = meta(view);
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var blockStarts = [];
    var blockRounds = [];
    var lastBlock = null;
    var lastRound = 0;
    events.forEach(function (event, i) {
      if (event.kind === "round") lastRound = event.round;
      var block = blockHead(event, lastRound);
      if (block !== lastBlock) {
        blockStarts.push(i);
        blockRounds.push(lastRound);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0 && blockRounds[r] !== blockRounds[r - 1]) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    events.forEach(function (event, i) {
      var kind = beatKind(event);
      if (!kind) return;
      markChemBeat(container, i, events.length, kind,
        event.kind === "act" ? event.seat : -1,
        beatLabel(event, nameMap, m), onSeek);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           labbar, endscreen, assetBase, payload}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var config = payload.config || {};
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    var tally = sealTally(events);
    var index = 0;
    var playing = true;
    var lastStep = 0;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      }, nameMap, states[0]);
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        return states[Math.min(index, states.length - 1)] ||
          { seats: [], phase: "", round: 0 };
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
        }
        effects.absorb(events.slice(0, index), jumped);
        renderFeed(options.feed, events, nameMap, index, currentState());
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent = matchHeader(currentState(), config,
            nameMap);
        }
        updateScorebug(options.scorebug, currentState(), nameMap);
        updateLabBar(options.labbar, currentState());
        // EVERY index change dismisses the endcard: updateEndscreen toggles
        // the .show class on each call, so a seek away from the end hides it.
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap, tally);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is looking at: a round open and the
        // exhibition get read, an act less so, a remark a little longer.
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs =
          !shown ? 1200 :
          shown.kind === "round" ? 1400 :
          shown.kind === "phase" ? 900 :
          shown.kind === "exhibition" ? 3000 :
          shown.kind === "end" ? 2000 :
          shown.kind === "act" ? (shown.say ? 1100 : 800) : 900;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var view = stateToView(currentState(), nameMap, effects, {
          done: index >= events.length && events.length > 0
        });
        renderer.draw(view);
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  window.CogchemistsRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle
  };
})();
