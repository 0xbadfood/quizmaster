import React from 'react';
import {
  AbsoluteFill,
  Html5Audio,
  Img,
  Sequence,
  interpolate,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import {
  COUNTDOWN_FRAMES,
  FADE_FRAMES,
  FINAL_BACKGROUND_FRAMES,
  INTRO_FRAMES,
  QUESTION_LEAD_FRAMES,
  TRANSITION_FRAMES,
  questionTiming,
} from './timing';
import type {QuizChoice, QuizVideoData, VideoQuestion} from './types';

const colors = {
  ink: '#10253d',
  deep: '#061a32',
  white: '#ffffff',
  paper: '#f7fbff',
  green: '#38a85b',
  greenDark: '#176e37',
  yellow: '#ffca3a',
  orange: '#f07828',
  muted: '#a9b8c7',
};

const Background: React.FC<{source: string; dim?: number}> = ({
  source,
  dim = 0,
}) => (
  <AbsoluteFill>
    <Img
      src={staticFile(source)}
      style={{width: '100%', height: '100%', objectFit: 'cover'}}
    />
    {dim > 0 ? (
      <AbsoluteFill style={{backgroundColor: `rgba(2, 14, 30, ${dim})`}} />
    ) : null}
  </AbsoluteFill>
);

const Progress: React.FC<{current: number; total: number}> = ({
  current,
  total,
}) => (
  <div
    style={{
      position: 'absolute',
      top: 60,
      left: 70,
      right: 70,
      height: 76,
      display: 'flex',
      alignItems: 'center',
    }}
  >
    {Array.from({length: total}, (_, index) => {
      const number = index + 1;
      const complete = number < current;
      const active = number === current;
      return (
        <React.Fragment key={number}>
          {index > 0 ? (
            <div
              style={{
                flex: 1,
                height: 8,
                backgroundColor: complete ? colors.green : 'rgba(255,255,255,0.4)',
                boxShadow: '0 2px 6px rgba(0,0,0,0.35)',
              }}
            />
          ) : null}
          <div
            style={{
              width: active ? 62 : 52,
              height: active ? 62 : 52,
              flex: `0 0 ${active ? 62 : 52}px`,
              borderRadius: '50%',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              backgroundColor: complete
                ? colors.green
                : active
                  ? colors.yellow
                  : 'rgba(247,251,255,0.92)',
              border: `4px solid ${active ? colors.orange : colors.white}`,
              color: active ? colors.ink : complete ? colors.white : '#5a6d80',
              fontSize: active ? 29 : 24,
              fontWeight: 900,
              boxShadow: '0 5px 12px rgba(0,0,0,0.35)',
            }}
          >
            {number}
          </div>
        </React.Fragment>
      );
    })}
  </div>
);

const Timer: React.FC<{
  localFrame: number;
  countdownStart: number;
  revealStart: number;
  fps: number;
}> = ({localFrame, countdownStart, revealStart, fps}) => {
  const countdownFrame = Math.max(0, localFrame - countdownStart);
  const active = localFrame >= countdownStart && localFrame < revealStart;
  const revealed = localFrame >= revealStart;
  const elapsed = Math.min(1, countdownFrame / COUNTDOWN_FRAMES);
  const remainingRatio = 1 - elapsed;
  const remaining = Math.max(
    1,
    Math.ceil((COUNTDOWN_FRAMES - countdownFrame) / fps),
  );

  return (
    <div
      style={{
        width: 132,
        height: 132,
        borderRadius: '50%',
        background: active
          ? `conic-gradient(${colors.yellow} ${remainingRatio * 360}deg, rgba(255,255,255,0.22) 0deg)`
          : revealed
            ? colors.green
            : 'rgba(255,255,255,0.18)',
        padding: 9,
        boxShadow: '0 8px 18px rgba(0,0,0,0.35)',
      }}
    >
      <div
        style={{
          width: '100%',
          height: '100%',
          borderRadius: '50%',
          backgroundColor: revealed ? colors.green : colors.deep,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          color: colors.white,
          fontSize: 58,
          fontWeight: 900,
        }}
      >
        {active ? remaining : revealed ? <CheckMark /> : '...'}
      </div>
    </div>
  );
};

const CheckMark: React.FC = () => (
  <div
    style={{
      width: 50,
      height: 27,
      borderLeft: `10px solid ${colors.white}`,
      borderBottom: `10px solid ${colors.white}`,
      transform: 'rotate(-45deg) translate(2px, -4px)',
    }}
  />
);

const ChoiceCard: React.FC<{
  choice: QuizChoice;
  revealed: boolean;
  correct: boolean;
}> = ({choice, revealed, correct}) => {
  const emphasized = revealed && correct;
  return (
    <div
      style={{
        height: 420,
        borderRadius: 8,
        overflow: 'hidden',
        backgroundColor: colors.paper,
        border: emphasized
          ? `10px solid ${colors.green}`
          : '5px solid rgba(255,255,255,0.92)',
        boxShadow: emphasized
          ? '0 0 0 8px rgba(255,202,58,0.9), 0 16px 32px rgba(0,0,0,0.45)'
          : '0 12px 28px rgba(0,0,0,0.38)',
        transform: emphasized ? 'scale(1.035)' : 'scale(1)',
        position: 'relative',
      }}
    >
      <div style={{height: 330, padding: 12, backgroundColor: colors.white}}>
        <Img
          src={staticFile(choice.image)}
          style={{width: '100%', height: '100%', objectFit: 'contain'}}
        />
      </div>
      <div
        style={{
          height: 90,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          padding: '0 18px',
          backgroundColor: emphasized ? '#dff6e5' : colors.paper,
          color: emphasized ? colors.greenDark : colors.ink,
          fontSize: choice.label.length > 18 ? 29 : 34,
          lineHeight: 1.08,
          fontWeight: 900,
          textAlign: 'center',
        }}
      >
        {choice.label}
      </div>
      {revealed && !correct ? (
        <div
          style={{
            position: 'absolute',
            inset: 0,
            backgroundColor: 'rgba(6,26,50,0.63)',
          }}
        />
      ) : null}
    </div>
  );
};

const QuestionScene: React.FC<{
  question: VideoQuestion;
  index: number;
  total: number;
  background: string;
  correctSfx: string;
}> = ({question, index, total, background, correctSfx}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const timing = questionTiming(question, fps);
  const revealed = frame >= timing.revealStart;
  const explanationVisible = frame >= timing.explanationStart;
  const entrance = spring({frame, fps, config: {damping: 18, stiffness: 120}});
  const exitOpacity = interpolate(
    frame,
    [timing.contentFrames - FADE_FRAMES, timing.contentFrames],
    [1, 0],
    {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'},
  );
  const explanationEntrance = spring({
    frame: Math.max(0, frame - timing.explanationStart),
    fps,
    config: {damping: 18, stiffness: 110},
  });

  return (
    <AbsoluteFill
      style={{
        opacity: exitOpacity,
        transform: `scale(${0.985 + entrance * 0.015})`,
        fontFamily: 'DejaVu Sans, sans-serif',
      }}
    >
      <Background source={background} dim={0.52} />
      <Progress current={index + 1} total={total} />

      <div
        style={{
          position: 'absolute',
          top: 170,
          left: 64,
          right: 64,
          minHeight: 272,
          backgroundColor: 'rgba(247,251,255,0.96)',
          borderTop: `10px solid ${colors.yellow}`,
          borderBottom: `10px solid ${colors.orange}`,
          boxShadow: '0 18px 38px rgba(0,0,0,0.42)',
          display: 'flex',
          alignItems: 'center',
          padding: '34px 34px 34px 44px',
          gap: 28,
        }}
      >
        <div style={{flex: 1}}>
          <div
            style={{
              color: colors.orange,
              fontSize: 25,
              fontWeight: 900,
              textTransform: 'uppercase',
              marginBottom: 15,
            }}
          >
            Question {index + 1} of {total}
          </div>
          <div
            style={{
              color: colors.ink,
              fontSize: question.question.length > 105 ? 38 : 43,
              lineHeight: 1.16,
              fontWeight: 900,
            }}
          >
            {question.question}
          </div>
        </div>
        <Timer
          localFrame={frame}
          countdownStart={timing.countdownStart}
          revealStart={timing.revealStart}
          fps={fps}
        />
      </div>

      <div
        style={{
          position: 'absolute',
          top: 495,
          left: 70,
          right: 70,
          display: 'grid',
          gridTemplateColumns: '1fr 1fr',
          gap: 30,
        }}
      >
        {question.choices.map((choice) => (
          <ChoiceCard
            key={choice.choiceId}
            choice={choice}
            revealed={revealed}
            correct={choice.choiceId === question.correctChoiceId}
          />
        ))}
      </div>

      {explanationVisible ? (
        <div
          style={{
            position: 'absolute',
            left: 70,
            right: 70,
            bottom: 55,
            minHeight: 235,
            backgroundColor: 'rgba(255,255,255,0.97)',
            borderLeft: `14px solid ${colors.green}`,
            borderRadius: 8,
            boxShadow: '0 16px 38px rgba(0,0,0,0.45)',
            padding: '32px 38px',
            transform: `translateY(${(1 - explanationEntrance) * 80}px)`,
            opacity: explanationEntrance,
          }}
        >
          <div
            style={{
              color: colors.greenDark,
              fontSize: 25,
              fontWeight: 900,
              textTransform: 'uppercase',
              marginBottom: 10,
            }}
          >
            Answer explained
          </div>
          <div
            style={{
              color: colors.ink,
              fontSize: question.explanation.length > 150 ? 32 : 37,
              lineHeight: 1.2,
              fontWeight: 800,
            }}
          >
            {question.explanation}
          </div>
        </div>
      ) : null}

      <Sequence from={QUESTION_LEAD_FRAMES} layout="none">
        <Html5Audio src={staticFile(question.questionAudio)} />
      </Sequence>
      <Sequence from={timing.revealStart} layout="none">
        <Html5Audio src={staticFile(correctSfx)} volume={0.82} />
      </Sequence>
      <Sequence from={timing.explanationStart} layout="none">
        <Html5Audio src={staticFile(question.explanationAudio)} />
      </Sequence>
    </AbsoluteFill>
  );
};

const FullBackground: React.FC<{source: string; fadeIn?: boolean}> = ({
  source,
  fadeIn = true,
}) => {
  const frame = useCurrentFrame();
  const opacity = fadeIn
    ? interpolate(frame, [0, FADE_FRAMES], [0, 1], {
        extrapolateLeft: 'clamp',
        extrapolateRight: 'clamp',
      })
    : 1;
  return (
    <AbsoluteFill style={{opacity}}>
      <Background source={source} />
    </AbsoluteFill>
  );
};

export const QuizVideo: React.FC<{data: QuizVideoData}> = ({data}) => {
  let cursor = INTRO_FRAMES;
  const sequences: React.ReactNode[] = [];

  data.questions.forEach((question, index) => {
    const timing = questionTiming(question, data.fps);
    sequences.push(
      <Sequence
        key={`question-${question.questionId}`}
        from={cursor}
        durationInFrames={timing.contentFrames}
      >
        <QuestionScene
          question={question}
          index={index}
          total={data.questions.length}
          background={data.background}
          correctSfx={data.correctSfx}
        />
      </Sequence>,
    );
    cursor += timing.contentFrames;
    const backgroundFrames =
      index === data.questions.length - 1
        ? FINAL_BACKGROUND_FRAMES
        : TRANSITION_FRAMES;
    sequences.push(
      <Sequence
        key={`background-${question.questionId}`}
        from={cursor}
        durationInFrames={backgroundFrames}
      >
        <FullBackground source={data.background} />
      </Sequence>,
    );
    cursor += backgroundFrames;
  });

  return (
    <AbsoluteFill style={{backgroundColor: colors.deep}}>
      <Background source={data.background} />
      <Sequence from={0} durationInFrames={INTRO_FRAMES}>
        <FullBackground source={data.background} fadeIn={false} />
      </Sequence>
      {sequences}
    </AbsoluteFill>
  );
};
