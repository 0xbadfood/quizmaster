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
}> = ({choice}) => {
  return (
    <div
      style={{
        height: 354,
        borderRadius: 8,
        overflow: 'hidden',
        backgroundColor: colors.paper,
        border: '4px solid rgba(255,255,255,0.94)',
        boxShadow: '0 12px 28px rgba(0,0,0,0.4)',
      }}
    >
      <div style={{height: 290, backgroundColor: colors.white}}>
        <Img
          src={staticFile(choice.image)}
          style={{width: '100%', height: '100%', objectFit: 'contain'}}
        />
      </div>
      <div
        style={{
          height: 64,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          padding: '0 14px 3px',
          backgroundColor: colors.paper,
          color: colors.ink,
          fontSize: choice.label.length > 18 ? 25 : 30,
          lineHeight: 1.08,
          fontWeight: 900,
          textAlign: 'center',
        }}
      >
        {choice.label}
      </div>
    </div>
  );
};

const AnswerOverlay: React.FC<{
  answer: QuizChoice;
  explanation: string;
  revealProgress: number;
  explanationProgress: number;
}> = ({answer, explanation, revealProgress, explanationProgress}) => (
  <div
    style={{
      position: 'absolute',
      top: 675,
      left: 70,
      right: 70,
      minHeight: 1090,
      borderRadius: 8,
      overflow: 'hidden',
      backgroundColor: 'rgba(247,251,255,0.97)',
      borderTop: `12px solid ${colors.green}`,
      borderBottom: `12px solid ${colors.yellow}`,
      boxShadow: '0 20px 50px rgba(0,0,0,0.52)',
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      padding: '38px 48px 44px',
      opacity: revealProgress,
      transform: `translateY(${(1 - revealProgress) * 70}px) scale(${0.96 + revealProgress * 0.04})`,
    }}
  >
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 22,
        color: colors.greenDark,
        fontSize: 31,
        fontWeight: 900,
        textTransform: 'uppercase',
      }}
    >
      <div
        style={{
          width: 66,
          height: 66,
          borderRadius: '50%',
          backgroundColor: colors.green,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
        }}
      >
        <CheckMark />
      </div>
      Correct answer
    </div>
    <div
      style={{
        width: 520,
        height: 520,
        marginTop: 30,
        backgroundColor: colors.white,
        border: `8px solid ${colors.green}`,
        borderRadius: 8,
        overflow: 'hidden',
        boxShadow: '0 14px 30px rgba(0,0,0,0.25)',
      }}
    >
      <Img
        src={staticFile(answer.image)}
        style={{width: '100%', height: '100%', objectFit: 'contain'}}
      />
    </div>
    <div
      style={{
        color: colors.ink,
        fontSize: answer.label.length > 22 ? 39 : 48,
        lineHeight: 1.08,
        fontWeight: 900,
        textAlign: 'center',
        marginTop: 24,
      }}
    >
      {answer.label}
    </div>
    <div
      style={{
        width: '100%',
        height: 3,
        backgroundColor: '#d5e0e8',
        margin: '28px 0 25px',
      }}
    />
    <div
      style={{
        color: colors.ink,
        fontSize: explanation.length > 150 ? 31 : 36,
        lineHeight: 1.22,
        fontWeight: 800,
        textAlign: 'center',
        opacity: explanationProgress,
        transform: `translateY(${(1 - explanationProgress) * 24}px)`,
      }}
    >
      {explanation}
    </div>
  </div>
);

const QuestionScene: React.FC<{
  question: VideoQuestion;
  index: number;
  total: number;
  background: string;
  timerAudio: string;
}> = ({question, index, total, background, timerAudio}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const timing = questionTiming(question, fps);
  const entrance = spring({frame, fps, config: {damping: 18, stiffness: 120}});
  const exitOpacity = interpolate(
    frame,
    [timing.contentFrames - FADE_FRAMES, timing.contentFrames],
    [1, 0],
    {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'},
  );
  const revealProgress = spring({
    frame: Math.max(0, frame - timing.revealStart),
    fps,
    config: {damping: 18, stiffness: 120},
  });
  const explanationProgress = spring({
    frame: Math.max(0, frame - timing.explanationStart),
    fps,
    config: {damping: 18, stiffness: 110},
  });
  const answer = question.choices.find(
    (choice) => choice.choiceId === question.correctChoiceId,
  );
  if (!answer) {
    throw new Error(`Correct answer is missing for ${question.questionId}`);
  }

  return (
    <AbsoluteFill
      style={{
        opacity: exitOpacity,
        transform: `scale(${0.985 + entrance * 0.015})`,
        fontFamily: 'DejaVu Sans, sans-serif',
      }}
    >
      <Background source={background} />
      <AbsoluteFill
        style={{
          background:
            'linear-gradient(to bottom, rgba(2,14,30,0.02) 0%, rgba(2,14,30,0.08) 36%, rgba(2,14,30,0.42) 100%)',
        }}
      />
      <Progress current={index + 1} total={total} />

      <div
        style={{
          position: 'absolute',
          top: 675,
          left: 64,
          right: 64,
          minHeight: 330,
          backgroundColor: 'rgba(247,251,255,0.96)',
          borderTop: `10px solid ${colors.yellow}`,
          borderBottom: `10px solid ${colors.orange}`,
          boxShadow: '0 18px 38px rgba(0,0,0,0.42)',
          display: 'flex',
          alignItems: 'center',
          padding: '34px 32px 34px 44px',
          gap: 28,
          opacity: 1 - revealProgress,
          transform: `translateY(${revealProgress * 30}px)`,
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
              fontSize: question.question.length > 105 ? 37 : 42,
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
          bottom: 42,
          left: 70,
          right: 70,
          display: 'grid',
          gridTemplateColumns: '1fr 1fr',
          gap: 22,
          opacity: 1 - revealProgress,
          transform: `translateY(${revealProgress * 45}px)`,
        }}
      >
        {question.choices.map((choice) => (
          <ChoiceCard key={choice.choiceId} choice={choice} />
        ))}
      </div>

      {frame >= timing.revealStart ? (
        <AnswerOverlay
          answer={answer}
          explanation={question.explanation}
          revealProgress={revealProgress}
          explanationProgress={explanationProgress}
        />
      ) : null}

      <Sequence from={QUESTION_LEAD_FRAMES} layout="none">
        <Html5Audio src={staticFile(question.questionAudio)} />
      </Sequence>
      <Sequence from={timing.countdownStart} layout="none">
        <Html5Audio src={staticFile(timerAudio)} volume={0.82} />
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
          timerAudio={data.timerAudio}
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
